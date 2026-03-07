#include <CoreAudio/AudioHardwareBase.h>
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "VirtualMicRingBuffer.h"

enum {
    kObjectID_PlugIn = kAudioObjectPlugInObject,
    kObjectID_Device = 2,
    kObjectID_Stream_Input = 3,
};

static const CFStringRef kPlugInName = CFSTR("MacAudio Virtual Mic Driver");
static const CFStringRef kManufacturerName = CFSTR("MacAudio");
static const CFStringRef kDeviceName = CFSTR("Virtual Mic");
static const CFStringRef kDeviceUID = CFSTR("com.skylarenns.macaudio.virtualmic.device");
static const CFStringRef kModelUID = CFSTR("com.skylarenns.macaudio.virtualmic.model");
static const CFStringRef kInputStreamName = CFSTR("Virtual Mic Input Stream");

static AudioServerPlugInHostRef gHost = NULL;
static _Atomic(uint32_t) gRefCount = 1U;
static _Atomic(uint32_t) gStartedClients = 0U;
static _Atomic(double) gSampleRate = 48000.0;
static _Atomic(uint32_t) gBufferFrameSize = 128U;
static _Atomic(uint64_t) gClockSeed = 1U;
static _Atomic(uint64_t) gCycleCounter = 0U;

static VMRingHandle* gRingReader = NULL;

#pragma mark Forward Declarations

static HRESULT STDMETHODCALLTYPE VirtualMic_QueryInterface(void* inDriver,
                                                           REFIID inUUID,
                                                           LPVOID* outInterface);
static ULONG STDMETHODCALLTYPE VirtualMic_AddRef(void* inDriver);
static ULONG STDMETHODCALLTYPE VirtualMic_Release(void* inDriver);

static OSStatus STDMETHODCALLTYPE VirtualMic_Initialize(AudioServerPlugInDriverRef inDriver,
                                                        AudioServerPlugInHostRef inHost);
static OSStatus STDMETHODCALLTYPE VirtualMic_CreateDevice(AudioServerPlugInDriverRef inDriver,
                                                          CFDictionaryRef inDescription,
                                                          const AudioServerPlugInClientInfo* inClientInfo,
                                                          AudioObjectID* outDeviceObjectID);
static OSStatus STDMETHODCALLTYPE VirtualMic_DestroyDevice(AudioServerPlugInDriverRef inDriver,
                                                           AudioObjectID inDeviceObjectID);
static OSStatus STDMETHODCALLTYPE VirtualMic_AddDeviceClient(AudioServerPlugInDriverRef inDriver,
                                                             AudioObjectID inDeviceObjectID,
                                                             const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus STDMETHODCALLTYPE VirtualMic_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver,
                                                                AudioObjectID inDeviceObjectID,
                                                                const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus STDMETHODCALLTYPE VirtualMic_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                                              AudioObjectID inDeviceObjectID,
                                                                              UInt64 inChangeAction,
                                                                              void* inChangeInfo);
static OSStatus STDMETHODCALLTYPE VirtualMic_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                                            AudioObjectID inDeviceObjectID,
                                                                            UInt64 inChangeAction,
                                                                            void* inChangeInfo);

static Boolean STDMETHODCALLTYPE VirtualMic_HasProperty(AudioServerPlugInDriverRef inDriver,
                                                        AudioObjectID inObjectID,
                                                        pid_t inClientProcessID,
                                                        const AudioObjectPropertyAddress* inAddress);
static OSStatus STDMETHODCALLTYPE VirtualMic_IsPropertySettable(AudioServerPlugInDriverRef inDriver,
                                                                AudioObjectID inObjectID,
                                                                pid_t inClientProcessID,
                                                                const AudioObjectPropertyAddress* inAddress,
                                                                Boolean* outIsSettable);
static OSStatus STDMETHODCALLTYPE VirtualMic_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver,
                                                                 AudioObjectID inObjectID,
                                                                 pid_t inClientProcessID,
                                                                 const AudioObjectPropertyAddress* inAddress,
                                                                 UInt32 inQualifierDataSize,
                                                                 const void* inQualifierData,
                                                                 UInt32* outDataSize);
static OSStatus STDMETHODCALLTYPE VirtualMic_GetPropertyData(AudioServerPlugInDriverRef inDriver,
                                                             AudioObjectID inObjectID,
                                                             pid_t inClientProcessID,
                                                             const AudioObjectPropertyAddress* inAddress,
                                                             UInt32 inQualifierDataSize,
                                                             const void* inQualifierData,
                                                             UInt32 inDataSize,
                                                             UInt32* outDataSize,
                                                             void* outData);
static OSStatus STDMETHODCALLTYPE VirtualMic_SetPropertyData(AudioServerPlugInDriverRef inDriver,
                                                             AudioObjectID inObjectID,
                                                             pid_t inClientProcessID,
                                                             const AudioObjectPropertyAddress* inAddress,
                                                             UInt32 inQualifierDataSize,
                                                             const void* inQualifierData,
                                                             UInt32 inDataSize,
                                                             const void* inData);

static OSStatus STDMETHODCALLTYPE VirtualMic_StartIO(AudioServerPlugInDriverRef inDriver,
                                                     AudioObjectID inDeviceObjectID,
                                                     UInt32 inClientID);
static OSStatus STDMETHODCALLTYPE VirtualMic_StopIO(AudioServerPlugInDriverRef inDriver,
                                                    AudioObjectID inDeviceObjectID,
                                                    UInt32 inClientID);
static OSStatus STDMETHODCALLTYPE VirtualMic_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver,
                                                              AudioObjectID inDeviceObjectID,
                                                              UInt32 inClientID,
                                                              Float64* outSampleTime,
                                                              UInt64* outHostTime,
                                                              UInt64* outSeed);
static OSStatus STDMETHODCALLTYPE VirtualMic_WillDoIOOperation(AudioServerPlugInDriverRef inDriver,
                                                               AudioObjectID inDeviceObjectID,
                                                               UInt32 inClientID,
                                                               UInt32 inOperationID,
                                                               Boolean* outWillDo,
                                                               Boolean* outWillDoInPlace);
static OSStatus STDMETHODCALLTYPE VirtualMic_BeginIOOperation(AudioServerPlugInDriverRef inDriver,
                                                              AudioObjectID inDeviceObjectID,
                                                              UInt32 inClientID,
                                                              UInt32 inOperationID,
                                                              UInt32 inIOBufferFrameSize,
                                                              const AudioServerPlugInIOCycleInfo* inIOCycleInfo);
static OSStatus STDMETHODCALLTYPE VirtualMic_DoIOOperation(AudioServerPlugInDriverRef inDriver,
                                                           AudioObjectID inDeviceObjectID,
                                                           AudioObjectID inStreamObjectID,
                                                           UInt32 inClientID,
                                                           UInt32 inOperationID,
                                                           UInt32 inIOBufferFrameSize,
                                                           const AudioServerPlugInIOCycleInfo* inIOCycleInfo,
                                                           void* ioMainBuffer,
                                                           void* ioSecondaryBuffer);
static OSStatus STDMETHODCALLTYPE VirtualMic_EndIOOperation(AudioServerPlugInDriverRef inDriver,
                                                            AudioObjectID inDeviceObjectID,
                                                            UInt32 inClientID,
                                                            UInt32 inOperationID,
                                                            UInt32 inIOBufferFrameSize,
                                                            const AudioServerPlugInIOCycleInfo* inIOCycleInfo);

static AudioServerPlugInDriverInterface gVirtualMicDriverInterface = {
    NULL,
    VirtualMic_QueryInterface,
    VirtualMic_AddRef,
    VirtualMic_Release,
    VirtualMic_Initialize,
    VirtualMic_CreateDevice,
    VirtualMic_DestroyDevice,
    VirtualMic_AddDeviceClient,
    VirtualMic_RemoveDeviceClient,
    VirtualMic_PerformDeviceConfigurationChange,
    VirtualMic_AbortDeviceConfigurationChange,
    VirtualMic_HasProperty,
    VirtualMic_IsPropertySettable,
    VirtualMic_GetPropertyDataSize,
    VirtualMic_GetPropertyData,
    VirtualMic_SetPropertyData,
    VirtualMic_StartIO,
    VirtualMic_StopIO,
    VirtualMic_GetZeroTimeStamp,
    VirtualMic_WillDoIOOperation,
    VirtualMic_BeginIOOperation,
    VirtualMic_DoIOOperation,
    VirtualMic_EndIOOperation,
};

static AudioServerPlugInDriverInterface* gVirtualMicDriverInterfacePtr = &gVirtualMicDriverInterface;
static AudioServerPlugInDriverRef gVirtualMicDriverRef = &gVirtualMicDriverInterfacePtr;

#pragma mark Helpers

static AudioStreamBasicDescription MakeStreamFormat(double sampleRate) {
    AudioStreamBasicDescription asbd;
    memset(&asbd, 0, sizeof(asbd));
    asbd.mSampleRate = sampleRate;
    asbd.mFormatID = kAudioFormatLinearPCM;
    asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved;
    asbd.mBytesPerPacket = sizeof(float);
    asbd.mFramesPerPacket = 1;
    asbd.mBytesPerFrame = sizeof(float);
    asbd.mChannelsPerFrame = 1;
    asbd.mBitsPerChannel = sizeof(float) * 8U;
    return asbd;
}

static OSStatus CopyCFStringToPropertyData(CFStringRef stringValue,
                                           UInt32 inDataSize,
                                           UInt32* outDataSize,
                                           void* outData) {
    if (inDataSize < sizeof(CFStringRef)) {
        return kAudioHardwareBadPropertySizeError;
    }

    *((CFStringRef*)outData) = CFRetain(stringValue);
    *outDataSize = sizeof(CFStringRef);
    return noErr;
}

static void NotifyDevicePropertyChanged(AudioObjectPropertySelector selector,
                                        AudioObjectPropertyScope scope) {
    if (gHost == NULL) {
        return;
    }

    AudioObjectPropertyAddress address = {
        .mSelector = selector,
        .mScope = scope,
        .mElement = kAudioObjectPropertyElementMain,
    };
    gHost->PropertiesChanged(gHost, kObjectID_Device, 1, &address);
}

static void NotifyStreamPropertyChanged(AudioObjectPropertySelector selector) {
    if (gHost == NULL) {
        return;
    }

    AudioObjectPropertyAddress address = {
        .mSelector = selector,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain,
    };
    gHost->PropertiesChanged(gHost, kObjectID_Stream_Input, 1, &address);
}

static bool IsInputScope(const AudioObjectPropertyAddress* inAddress) {
    return inAddress->mScope == kAudioObjectPropertyScopeGlobal || inAddress->mScope == kAudioObjectPropertyScopeInput;
}

static bool OpenRingReaderIfNeeded(void) {
    if (gRingReader != NULL) {
        return true;
    }

    VMRingHandle* reader = NULL;
    const int err = vm_ring_open_reader(VM_RING_DEFAULT_NAME, &reader);
    if (err == 0 && reader != NULL) {
        gRingReader = reader;
        return true;
    }
    return false;
}

#pragma mark Factory

void* VirtualMicDriver_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID) {
    (void)inAllocator;

    if (!CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        return NULL;
    }

    VirtualMic_AddRef(gVirtualMicDriverRef);
    return gVirtualMicDriverRef;
}

#pragma mark COM Interface

static HRESULT STDMETHODCALLTYPE VirtualMic_QueryInterface(void* inDriver,
                                                           REFIID inUUID,
                                                           LPVOID* outInterface) {
    (void)inDriver;
    if (outInterface == NULL) {
        return E_POINTER;
    }

    *outInterface = NULL;

    CFUUIDRef uuid = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    if (uuid == NULL) {
        return E_NOINTERFACE;
    }

    const bool isIUnknown = CFEqual(uuid, IUnknownUUID);
    const bool isDriverInterface = CFEqual(uuid, kAudioServerPlugInDriverInterfaceUUID);
    CFRelease(uuid);

    if (!isIUnknown && !isDriverInterface) {
        return E_NOINTERFACE;
    }

    VirtualMic_AddRef(gVirtualMicDriverRef);
    *outInterface = gVirtualMicDriverRef;
    return S_OK;
}

static ULONG STDMETHODCALLTYPE VirtualMic_AddRef(void* inDriver) {
    (void)inDriver;
    return atomic_fetch_add_explicit(&gRefCount, 1U, memory_order_relaxed) + 1U;
}

static ULONG STDMETHODCALLTYPE VirtualMic_Release(void* inDriver) {
    (void)inDriver;
    const uint32_t old = atomic_fetch_sub_explicit(&gRefCount, 1U, memory_order_relaxed);
    return old > 0U ? old - 1U : 0U;
}

#pragma mark Basic Driver Operations

static OSStatus STDMETHODCALLTYPE VirtualMic_Initialize(AudioServerPlugInDriverRef inDriver,
                                                        AudioServerPlugInHostRef inHost) {
    if (inDriver != gVirtualMicDriverRef) {
        return kAudioHardwareBadObjectError;
    }

    gHost = inHost;
    OpenRingReaderIfNeeded();
    return noErr;
}

static OSStatus STDMETHODCALLTYPE VirtualMic_CreateDevice(AudioServerPlugInDriverRef inDriver,
                                                          CFDictionaryRef inDescription,
                                                          const AudioServerPlugInClientInfo* inClientInfo,
                                                          AudioObjectID* outDeviceObjectID) {
    (void)inDriver;
    (void)inDescription;
    (void)inClientInfo;
    (void)outDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus STDMETHODCALLTYPE VirtualMic_DestroyDevice(AudioServerPlugInDriverRef inDriver,
                                                           AudioObjectID inDeviceObjectID) {
    (void)inDriver;
    (void)inDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus STDMETHODCALLTYPE VirtualMic_AddDeviceClient(AudioServerPlugInDriverRef inDriver,
                                                             AudioObjectID inDeviceObjectID,
                                                             const AudioServerPlugInClientInfo* inClientInfo) {
    (void)inDriver;
    (void)inDeviceObjectID;
    (void)inClientInfo;
    return noErr;
}

static OSStatus STDMETHODCALLTYPE VirtualMic_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver,
                                                                AudioObjectID inDeviceObjectID,
                                                                const AudioServerPlugInClientInfo* inClientInfo) {
    (void)inDriver;
    (void)inDeviceObjectID;
    (void)inClientInfo;
    return noErr;
}

static OSStatus STDMETHODCALLTYPE VirtualMic_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                                              AudioObjectID inDeviceObjectID,
                                                                              UInt64 inChangeAction,
                                                                              void* inChangeInfo) {
    (void)inDriver;
    (void)inDeviceObjectID;
    (void)inChangeAction;
    (void)inChangeInfo;
    return noErr;
}

static OSStatus STDMETHODCALLTYPE VirtualMic_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                                            AudioObjectID inDeviceObjectID,
                                                                            UInt64 inChangeAction,
                                                                            void* inChangeInfo) {
    (void)inDriver;
    (void)inDeviceObjectID;
    (void)inChangeAction;
    (void)inChangeInfo;
    return noErr;
}

#pragma mark Property Operations

static Boolean STDMETHODCALLTYPE VirtualMic_HasProperty(AudioServerPlugInDriverRef inDriver,
                                                        AudioObjectID inObjectID,
                                                        pid_t inClientProcessID,
                                                        const AudioObjectPropertyAddress* inAddress) {
    (void)inDriver;
    (void)inClientProcessID;

    switch (inObjectID) {
        case kObjectID_PlugIn:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyManufacturer:
                case kAudioObjectPropertyName:
                case kAudioObjectPropertyOwnedObjects:
                case kAudioPlugInPropertyDeviceList:
                case kAudioPlugInPropertyTranslateUIDToDevice:
                    return true;
                default:
                    return false;
            }

        case kObjectID_Device:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyName:
                case kAudioObjectPropertyManufacturer:
                case kAudioObjectPropertyOwnedObjects:
                case kAudioDevicePropertyDeviceUID:
                case kAudioDevicePropertyModelUID:
                case kAudioDevicePropertyTransportType:
                case kAudioDevicePropertyClockDomain:
                case kAudioDevicePropertyDeviceIsAlive:
                case kAudioDevicePropertyDeviceIsRunning:
                case kAudioDevicePropertyStreams:
                case kAudioDevicePropertyNominalSampleRate:
                case kAudioDevicePropertyAvailableNominalSampleRates:
                case kAudioDevicePropertyBufferFrameSize:
                case kAudioDevicePropertyBufferFrameSizeRange:
                case kAudioDevicePropertyUsesVariableBufferFrameSizes:
                case kAudioDevicePropertyStreamConfiguration:
                case kAudioDevicePropertySafetyOffset:
                case kAudioDevicePropertyLatency:
                case kAudioDevicePropertyZeroTimeStampPeriod:
                case kAudioDevicePropertyPreferredChannelsForStereo:
                case kAudioDevicePropertyRelatedDevices:
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                    return true;
                default:
                    return false;
            }

        case kObjectID_Stream_Input:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyName:
                case kAudioStreamPropertyDirection:
                case kAudioStreamPropertyTerminalType:
                case kAudioStreamPropertyStartingChannel:
                case kAudioStreamPropertyLatency:
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat:
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats:
                    return true;
                default:
                    return false;
            }

        default:
            return false;
    }
}

static OSStatus STDMETHODCALLTYPE VirtualMic_IsPropertySettable(AudioServerPlugInDriverRef inDriver,
                                                                AudioObjectID inObjectID,
                                                                pid_t inClientProcessID,
                                                                const AudioObjectPropertyAddress* inAddress,
                                                                Boolean* outIsSettable) {
    (void)inDriver;
    (void)inClientProcessID;

    if (outIsSettable == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    switch (inObjectID) {
        case kObjectID_Device:
            switch (inAddress->mSelector) {
                case kAudioDevicePropertyNominalSampleRate:
                case kAudioDevicePropertyBufferFrameSize:
                    *outIsSettable = true;
                    return noErr;
                default:
                    *outIsSettable = false;
                    return noErr;
            }

        case kObjectID_Stream_Input:
            switch (inAddress->mSelector) {
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat:
                    *outIsSettable = true;
                    return noErr;
                default:
                    *outIsSettable = false;
                    return noErr;
            }

        default:
            *outIsSettable = false;
            return noErr;
    }
}

static OSStatus STDMETHODCALLTYPE VirtualMic_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver,
                                                                 AudioObjectID inObjectID,
                                                                 pid_t inClientProcessID,
                                                                 const AudioObjectPropertyAddress* inAddress,
                                                                 UInt32 inQualifierDataSize,
                                                                 const void* inQualifierData,
                                                                 UInt32* outDataSize) {
    (void)inDriver;
    (void)inClientProcessID;
    (void)inQualifierDataSize;
    (void)inQualifierData;

    if (outDataSize == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    switch (inObjectID) {
        case kObjectID_PlugIn:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyManufacturer:
                case kAudioObjectPropertyName:
                    *outDataSize = sizeof(CFStringRef);
                    return noErr;
                case kAudioObjectPropertyOwnedObjects:
                case kAudioPlugInPropertyDeviceList:
                case kAudioPlugInPropertyTranslateUIDToDevice:
                    *outDataSize = sizeof(AudioObjectID);
                    return noErr;
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                    *outDataSize = sizeof(AudioClassID);
                    return noErr;
                default:
                    return kAudioHardwareUnknownPropertyError;
            }

        case kObjectID_Device:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioDevicePropertyTransportType:
                case kAudioDevicePropertyClockDomain:
                case kAudioDevicePropertyDeviceIsAlive:
                case kAudioDevicePropertyDeviceIsRunning:
                case kAudioDevicePropertyBufferFrameSize:
                case kAudioDevicePropertySafetyOffset:
                case kAudioDevicePropertyLatency:
                case kAudioDevicePropertyZeroTimeStampPeriod:
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                    *outDataSize = sizeof(UInt32);
                    return noErr;

                case kAudioObjectPropertyName:
                case kAudioObjectPropertyManufacturer:
                case kAudioDevicePropertyDeviceUID:
                case kAudioDevicePropertyModelUID:
                    *outDataSize = sizeof(CFStringRef);
                    return noErr;

                case kAudioObjectPropertyOwnedObjects:
                case kAudioDevicePropertyRelatedDevices:
                    *outDataSize = sizeof(AudioObjectID);
                    return noErr;

                case kAudioDevicePropertyStreams:
                    *outDataSize = IsInputScope(inAddress) ? sizeof(AudioObjectID) : 0U;
                    return noErr;

                case kAudioDevicePropertyNominalSampleRate:
                    *outDataSize = sizeof(Float64);
                    return noErr;

                case kAudioDevicePropertyAvailableNominalSampleRates:
                    *outDataSize = (UInt32)(2U * sizeof(AudioValueRange));
                    return noErr;

                case kAudioDevicePropertyBufferFrameSizeRange:
                    *outDataSize = sizeof(AudioValueRange);
                    return noErr;

                case kAudioDevicePropertyUsesVariableBufferFrameSizes:
                    *outDataSize = sizeof(UInt32);
                    return noErr;

                case kAudioDevicePropertyStreamConfiguration:
                    *outDataSize = (UInt32)(offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer));
                    return noErr;

                case kAudioDevicePropertyPreferredChannelsForStereo:
                    *outDataSize = sizeof(UInt32) * 2U;
                    return noErr;

                default:
                    return kAudioHardwareUnknownPropertyError;
            }

        case kObjectID_Stream_Input:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioStreamPropertyDirection:
                case kAudioStreamPropertyTerminalType:
                case kAudioStreamPropertyStartingChannel:
                case kAudioStreamPropertyLatency:
                    *outDataSize = sizeof(UInt32);
                    return noErr;

                case kAudioObjectPropertyName:
                    *outDataSize = sizeof(CFStringRef);
                    return noErr;

                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat:
                    *outDataSize = sizeof(AudioStreamBasicDescription);
                    return noErr;

                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats:
                    *outDataSize = (UInt32)(2U * sizeof(AudioStreamRangedDescription));
                    return noErr;

                default:
                    return kAudioHardwareUnknownPropertyError;
            }

        default:
            return kAudioHardwareBadObjectError;
    }
}

static OSStatus STDMETHODCALLTYPE VirtualMic_GetPropertyData(AudioServerPlugInDriverRef inDriver,
                                                             AudioObjectID inObjectID,
                                                             pid_t inClientProcessID,
                                                             const AudioObjectPropertyAddress* inAddress,
                                                             UInt32 inQualifierDataSize,
                                                             const void* inQualifierData,
                                                             UInt32 inDataSize,
                                                             UInt32* outDataSize,
                                                             void* outData) {
    (void)inDriver;
    (void)inClientProcessID;

    if (outDataSize == NULL || outData == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    switch (inObjectID) {
        case kObjectID_PlugIn:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    if (inDataSize < sizeof(AudioClassID)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *((AudioClassID*)outData) = kAudioObjectClassID;
                    *outDataSize = sizeof(AudioClassID);
                    return noErr;

                case kAudioObjectPropertyClass:
                    if (inDataSize < sizeof(AudioClassID)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *((AudioClassID*)outData) = kAudioPlugInClassID;
                    *outDataSize = sizeof(AudioClassID);
                    return noErr;

                case kAudioObjectPropertyOwner:
                    if (inDataSize < sizeof(AudioObjectID)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *((AudioObjectID*)outData) = kAudioObjectSystemObject;
                    *outDataSize = sizeof(AudioObjectID);
                    return noErr;

                case kAudioObjectPropertyManufacturer:
                    return CopyCFStringToPropertyData(kManufacturerName, inDataSize, outDataSize, outData);

                case kAudioObjectPropertyName:
                    return CopyCFStringToPropertyData(kPlugInName, inDataSize, outDataSize, outData);

                case kAudioObjectPropertyOwnedObjects:
                case kAudioPlugInPropertyDeviceList:
                    if (inDataSize < sizeof(AudioObjectID)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *((AudioObjectID*)outData) = kObjectID_Device;
                    *outDataSize = sizeof(AudioObjectID);
                    return noErr;

                case kAudioPlugInPropertyTranslateUIDToDevice: {
                    if (inDataSize < sizeof(AudioObjectID)) {
                        return kAudioHardwareBadPropertySizeError;
                    }

                    AudioObjectID translatedID = kAudioObjectUnknown;
                    if (inQualifierDataSize == sizeof(CFStringRef) && inQualifierData != NULL) {
                        CFStringRef requestedUID = *((CFStringRef*)inQualifierData);
                        if (requestedUID != NULL && CFEqual(requestedUID, kDeviceUID)) {
                            translatedID = kObjectID_Device;
                        }
                    }

                    *((AudioObjectID*)outData) = translatedID;
                    *outDataSize = sizeof(AudioObjectID);
                    return noErr;
                }

                default:
                    return kAudioHardwareUnknownPropertyError;
            }

        case kObjectID_Device:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    if (inDataSize < sizeof(AudioClassID)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *((AudioClassID*)outData) = kAudioObjectClassID;
                    *outDataSize = sizeof(AudioClassID);
                    return noErr;

                case kAudioObjectPropertyClass:
                    if (inDataSize < sizeof(AudioClassID)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *((AudioClassID*)outData) = kAudioDeviceClassID;
                    *outDataSize = sizeof(AudioClassID);
                    return noErr;

                case kAudioObjectPropertyOwner:
                    if (inDataSize < sizeof(AudioObjectID)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *((AudioObjectID*)outData) = kObjectID_PlugIn;
                    *outDataSize = sizeof(AudioObjectID);
                    return noErr;

                case kAudioObjectPropertyName:
                    return CopyCFStringToPropertyData(kDeviceName, inDataSize, outDataSize, outData);

                case kAudioObjectPropertyManufacturer:
                    return CopyCFStringToPropertyData(kManufacturerName, inDataSize, outDataSize, outData);

                case kAudioObjectPropertyOwnedObjects:
                    if (inDataSize < sizeof(AudioObjectID)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *((AudioObjectID*)outData) = kObjectID_Stream_Input;
                    *outDataSize = sizeof(AudioObjectID);
                    return noErr;

                case kAudioDevicePropertyDeviceUID:
                    return CopyCFStringToPropertyData(kDeviceUID, inDataSize, outDataSize, outData);

                case kAudioDevicePropertyModelUID:
                    return CopyCFStringToPropertyData(kModelUID, inDataSize, outDataSize, outData);

                case kAudioDevicePropertyTransportType:
                    if (inDataSize < sizeof(UInt32)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *((UInt32*)outData) = kAudioDeviceTransportTypeVirtual;
                    *outDataSize = sizeof(UInt32);
                    return noErr;

                case kAudioDevicePropertyClockDomain:
                    if (inDataSize < sizeof(UInt32)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *((UInt32*)outData) = 0U;
                    *outDataSize = sizeof(UInt32);
                    return noErr;

                case kAudioDevicePropertyDeviceIsAlive:
                    if (inDataSize < sizeof(UInt32)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *((UInt32*)outData) = 1U;
                    *outDataSize = sizeof(UInt32);
                    return noErr;

                case kAudioDevicePropertyDeviceIsRunning:
                    if (inDataSize < sizeof(UInt32)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *((UInt32*)outData) = atomic_load_explicit(&gStartedClients, memory_order_relaxed) > 0U ? 1U : 0U;
                    *outDataSize = sizeof(UInt32);
                    return noErr;

                case kAudioDevicePropertyStreams:
                    if (!IsInputScope(inAddress)) {
                        *outDataSize = 0U;
                        return noErr;
                    }
                    if (inDataSize < sizeof(AudioObjectID)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *((AudioObjectID*)outData) = kObjectID_Stream_Input;
                    *outDataSize = sizeof(AudioObjectID);
                    return noErr;

                case kAudioDevicePropertyNominalSampleRate:
                    if (inDataSize < sizeof(Float64)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *((Float64*)outData) = atomic_load_explicit(&gSampleRate, memory_order_relaxed);
                    *outDataSize = sizeof(Float64);
                    return noErr;

                case kAudioDevicePropertyAvailableNominalSampleRates: {
                    if (inDataSize < sizeof(AudioValueRange) * 2U) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    AudioValueRange* rates = (AudioValueRange*)outData;
                    rates[0].mMinimum = 44100.0;
                    rates[0].mMaximum = 44100.0;
                    rates[1].mMinimum = 48000.0;
                    rates[1].mMaximum = 48000.0;
                    *outDataSize = sizeof(AudioValueRange) * 2U;
                    return noErr;
                }

                case kAudioDevicePropertyBufferFrameSize:
                    if (inDataSize < sizeof(UInt32)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *((UInt32*)outData) = atomic_load_explicit(&gBufferFrameSize, memory_order_relaxed);
                    *outDataSize = sizeof(UInt32);
                    return noErr;

                case kAudioDevicePropertyBufferFrameSizeRange: {
                    if (inDataSize < sizeof(AudioValueRange)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    AudioValueRange* range = (AudioValueRange*)outData;
                    range->mMinimum = 64.0;
                    range->mMaximum = 256.0;
                    *outDataSize = sizeof(AudioValueRange);
                    return noErr;
                }

                case kAudioDevicePropertyUsesVariableBufferFrameSizes:
                    if (inDataSize < sizeof(UInt32)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *((UInt32*)outData) = 0U;
                    *outDataSize = sizeof(UInt32);
                    return noErr;

                case kAudioDevicePropertyStreamConfiguration: {
                    const UInt32 requiredSize = (UInt32)(offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer));
                    if (inDataSize < requiredSize) {
                        return kAudioHardwareBadPropertySizeError;
                    }

                    AudioBufferList* bufferList = (AudioBufferList*)outData;
                    bufferList->mNumberBuffers = IsInputScope(inAddress) ? 1U : 0U;
                    if (bufferList->mNumberBuffers > 0U) {
                        bufferList->mBuffers[0].mNumberChannels = 1U;
                        bufferList->mBuffers[0].mDataByteSize = 0U;
                        bufferList->mBuffers[0].mData = NULL;
                    }
                    *outDataSize = requiredSize;
                    return noErr;
                }

                case kAudioDevicePropertySafetyOffset:
                case kAudioDevicePropertyLatency:
                    if (inDataSize < sizeof(UInt32)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *((UInt32*)outData) = 0U;
                    *outDataSize = sizeof(UInt32);
                    return noErr;

                case kAudioDevicePropertyZeroTimeStampPeriod:
                    if (inDataSize < sizeof(UInt32)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *((UInt32*)outData) = atomic_load_explicit(&gBufferFrameSize, memory_order_relaxed);
                    *outDataSize = sizeof(UInt32);
                    return noErr;

                case kAudioDevicePropertyPreferredChannelsForStereo:
                    if (inDataSize < sizeof(UInt32) * 2U) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    ((UInt32*)outData)[0] = 1U;
                    ((UInt32*)outData)[1] = 1U;
                    *outDataSize = sizeof(UInt32) * 2U;
                    return noErr;

                case kAudioDevicePropertyRelatedDevices:
                    if (inDataSize < sizeof(AudioObjectID)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *((AudioObjectID*)outData) = kObjectID_Device;
                    *outDataSize = sizeof(AudioObjectID);
                    return noErr;

                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                    if (inDataSize < sizeof(UInt32)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *((UInt32*)outData) = (inAddress->mScope == kAudioObjectPropertyScopeInput) ? 1U : 0U;
                    *outDataSize = sizeof(UInt32);
                    return noErr;

                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                    if (inDataSize < sizeof(UInt32)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *((UInt32*)outData) = 0U;
                    *outDataSize = sizeof(UInt32);
                    return noErr;

                default:
                    return kAudioHardwareUnknownPropertyError;
            }

        case kObjectID_Stream_Input:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    if (inDataSize < sizeof(AudioClassID)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *((AudioClassID*)outData) = kAudioObjectClassID;
                    *outDataSize = sizeof(AudioClassID);
                    return noErr;

                case kAudioObjectPropertyClass:
                    if (inDataSize < sizeof(AudioClassID)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *((AudioClassID*)outData) = kAudioStreamClassID;
                    *outDataSize = sizeof(AudioClassID);
                    return noErr;

                case kAudioObjectPropertyOwner:
                    if (inDataSize < sizeof(AudioObjectID)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *((AudioObjectID*)outData) = kObjectID_Device;
                    *outDataSize = sizeof(AudioObjectID);
                    return noErr;

                case kAudioObjectPropertyName:
                    return CopyCFStringToPropertyData(kInputStreamName, inDataSize, outDataSize, outData);

                case kAudioStreamPropertyDirection:
                    if (inDataSize < sizeof(UInt32)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *((UInt32*)outData) = 1U;
                    *outDataSize = sizeof(UInt32);
                    return noErr;

                case kAudioStreamPropertyTerminalType:
                    if (inDataSize < sizeof(UInt32)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *((UInt32*)outData) = kAudioStreamTerminalTypeMicrophone;
                    *outDataSize = sizeof(UInt32);
                    return noErr;

                case kAudioStreamPropertyStartingChannel:
                    if (inDataSize < sizeof(UInt32)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *((UInt32*)outData) = 1U;
                    *outDataSize = sizeof(UInt32);
                    return noErr;

                case kAudioStreamPropertyLatency:
                    if (inDataSize < sizeof(UInt32)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *((UInt32*)outData) = 0U;
                    *outDataSize = sizeof(UInt32);
                    return noErr;

                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat:
                    if (inDataSize < sizeof(AudioStreamBasicDescription)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *((AudioStreamBasicDescription*)outData) = MakeStreamFormat(atomic_load_explicit(&gSampleRate, memory_order_relaxed));
                    *outDataSize = sizeof(AudioStreamBasicDescription);
                    return noErr;

                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats: {
                    if (inDataSize < sizeof(AudioStreamRangedDescription) * 2U) {
                        return kAudioHardwareBadPropertySizeError;
                    }

                    AudioStreamRangedDescription* ranges = (AudioStreamRangedDescription*)outData;
                    ranges[0].mFormat = MakeStreamFormat(44100.0);
                    ranges[0].mSampleRateRange.mMinimum = 44100.0;
                    ranges[0].mSampleRateRange.mMaximum = 44100.0;
                    ranges[1].mFormat = MakeStreamFormat(48000.0);
                    ranges[1].mSampleRateRange.mMinimum = 48000.0;
                    ranges[1].mSampleRateRange.mMaximum = 48000.0;
                    *outDataSize = sizeof(AudioStreamRangedDescription) * 2U;
                    return noErr;
                }

                default:
                    return kAudioHardwareUnknownPropertyError;
            }

        default:
            return kAudioHardwareBadObjectError;
    }
}

static OSStatus STDMETHODCALLTYPE VirtualMic_SetPropertyData(AudioServerPlugInDriverRef inDriver,
                                                             AudioObjectID inObjectID,
                                                             pid_t inClientProcessID,
                                                             const AudioObjectPropertyAddress* inAddress,
                                                             UInt32 inQualifierDataSize,
                                                             const void* inQualifierData,
                                                             UInt32 inDataSize,
                                                             const void* inData) {
    (void)inDriver;
    (void)inClientProcessID;
    (void)inQualifierDataSize;
    (void)inQualifierData;

    if (inData == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    if (inObjectID == kObjectID_Device) {
        if (inAddress->mSelector == kAudioDevicePropertyNominalSampleRate) {
            if (inDataSize != sizeof(Float64)) {
                return kAudioHardwareBadPropertySizeError;
            }

            const Float64 sampleRate = *((const Float64*)inData);
            if (sampleRate != 44100.0 && sampleRate != 48000.0) {
                return kAudioHardwareIllegalOperationError;
            }

            atomic_store_explicit(&gSampleRate, sampleRate, memory_order_relaxed);
            atomic_fetch_add_explicit(&gClockSeed, 1U, memory_order_relaxed);

            NotifyDevicePropertyChanged(kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal);
            NotifyStreamPropertyChanged(kAudioStreamPropertyVirtualFormat);
            NotifyStreamPropertyChanged(kAudioStreamPropertyPhysicalFormat);
            return noErr;
        }

        if (inAddress->mSelector == kAudioDevicePropertyBufferFrameSize) {
            if (inDataSize != sizeof(UInt32)) {
                return kAudioHardwareBadPropertySizeError;
            }

            UInt32 frameSize = *((const UInt32*)inData);
            if (frameSize < 64U) {
                frameSize = 64U;
            }
            if (frameSize > 256U) {
                frameSize = 256U;
            }

            atomic_store_explicit(&gBufferFrameSize, frameSize, memory_order_relaxed);
            atomic_fetch_add_explicit(&gClockSeed, 1U, memory_order_relaxed);

            NotifyDevicePropertyChanged(kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal);
            NotifyDevicePropertyChanged(kAudioDevicePropertyZeroTimeStampPeriod, kAudioObjectPropertyScopeGlobal);
            return noErr;
        }
    }

    if (inObjectID == kObjectID_Stream_Input &&
        (inAddress->mSelector == kAudioStreamPropertyVirtualFormat || inAddress->mSelector == kAudioStreamPropertyPhysicalFormat)) {
        if (inDataSize != sizeof(AudioStreamBasicDescription)) {
            return kAudioHardwareBadPropertySizeError;
        }

        const AudioStreamBasicDescription* asbd = (const AudioStreamBasicDescription*)inData;
        if (asbd->mSampleRate != 44100.0 && asbd->mSampleRate != 48000.0) {
            return kAudioHardwareIllegalOperationError;
        }

        atomic_store_explicit(&gSampleRate, asbd->mSampleRate, memory_order_relaxed);
        atomic_fetch_add_explicit(&gClockSeed, 1U, memory_order_relaxed);

        NotifyDevicePropertyChanged(kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal);
        NotifyStreamPropertyChanged(kAudioStreamPropertyVirtualFormat);
        NotifyStreamPropertyChanged(kAudioStreamPropertyPhysicalFormat);
        return noErr;
    }

    return kAudioHardwareUnknownPropertyError;
}

#pragma mark IO Operations

static OSStatus STDMETHODCALLTYPE VirtualMic_StartIO(AudioServerPlugInDriverRef inDriver,
                                                     AudioObjectID inDeviceObjectID,
                                                     UInt32 inClientID) {
    (void)inDriver;
    (void)inClientID;

    if (inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }

    const uint32_t oldCount = atomic_fetch_add_explicit(&gStartedClients, 1U, memory_order_relaxed);
    if (oldCount == 0U) {
        atomic_store_explicit(&gCycleCounter, 0U, memory_order_relaxed);
        NotifyDevicePropertyChanged(kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal);
    }

    OpenRingReaderIfNeeded();
    return noErr;
}

static OSStatus STDMETHODCALLTYPE VirtualMic_StopIO(AudioServerPlugInDriverRef inDriver,
                                                    AudioObjectID inDeviceObjectID,
                                                    UInt32 inClientID) {
    (void)inDriver;
    (void)inClientID;

    if (inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }

    const uint32_t oldCount = atomic_load_explicit(&gStartedClients, memory_order_relaxed);
    if (oldCount > 0U) {
        const uint32_t newCount = atomic_fetch_sub_explicit(&gStartedClients, 1U, memory_order_relaxed) - 1U;
        if (newCount == 0U) {
            NotifyDevicePropertyChanged(kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal);
        }
    }

    return noErr;
}

static OSStatus STDMETHODCALLTYPE VirtualMic_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver,
                                                              AudioObjectID inDeviceObjectID,
                                                              UInt32 inClientID,
                                                              Float64* outSampleTime,
                                                              UInt64* outHostTime,
                                                              UInt64* outSeed) {
    (void)inDriver;
    (void)inClientID;

    if (inDeviceObjectID != kObjectID_Device || outSampleTime == NULL || outHostTime == NULL || outSeed == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    const uint64_t cycle = atomic_fetch_add_explicit(&gCycleCounter, 1U, memory_order_relaxed);
    const uint32_t bufferFrames = atomic_load_explicit(&gBufferFrameSize, memory_order_relaxed);

    *outSampleTime = (Float64)(cycle * bufferFrames);
    *outHostTime = mach_absolute_time();
    *outSeed = atomic_load_explicit(&gClockSeed, memory_order_relaxed);
    return noErr;
}

static OSStatus STDMETHODCALLTYPE VirtualMic_WillDoIOOperation(AudioServerPlugInDriverRef inDriver,
                                                               AudioObjectID inDeviceObjectID,
                                                               UInt32 inClientID,
                                                               UInt32 inOperationID,
                                                               Boolean* outWillDo,
                                                               Boolean* outWillDoInPlace) {
    (void)inDriver;
    (void)inClientID;

    if (inDeviceObjectID != kObjectID_Device || outWillDo == NULL || outWillDoInPlace == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    *outWillDo = false;
    *outWillDoInPlace = true;

    if (inOperationID == kAudioServerPlugInIOOperationReadInput) {
        *outWillDo = true;
    }

    return noErr;
}

static OSStatus STDMETHODCALLTYPE VirtualMic_BeginIOOperation(AudioServerPlugInDriverRef inDriver,
                                                              AudioObjectID inDeviceObjectID,
                                                              UInt32 inClientID,
                                                              UInt32 inOperationID,
                                                              UInt32 inIOBufferFrameSize,
                                                              const AudioServerPlugInIOCycleInfo* inIOCycleInfo) {
    (void)inDriver;
    (void)inDeviceObjectID;
    (void)inClientID;
    (void)inOperationID;
    (void)inIOBufferFrameSize;
    (void)inIOCycleInfo;
    return noErr;
}

static OSStatus STDMETHODCALLTYPE VirtualMic_DoIOOperation(AudioServerPlugInDriverRef inDriver,
                                                           AudioObjectID inDeviceObjectID,
                                                           AudioObjectID inStreamObjectID,
                                                           UInt32 inClientID,
                                                           UInt32 inOperationID,
                                                           UInt32 inIOBufferFrameSize,
                                                           const AudioServerPlugInIOCycleInfo* inIOCycleInfo,
                                                           void* ioMainBuffer,
                                                           void* ioSecondaryBuffer) {
    (void)inDriver;
    (void)inClientID;
    (void)inIOCycleInfo;
    (void)ioSecondaryBuffer;

    if (inDeviceObjectID != kObjectID_Device || inStreamObjectID != kObjectID_Stream_Input) {
        return kAudioHardwareBadObjectError;
    }

    if (inOperationID != kAudioServerPlugInIOOperationReadInput) {
        return noErr;
    }

    if (ioMainBuffer == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    AudioBufferList* ioBufferList = (AudioBufferList*)ioMainBuffer;
    if (ioBufferList->mNumberBuffers == 0U) {
        return noErr;
    }

    OpenRingReaderIfNeeded();

    float* firstBuffer = (float*)ioBufferList->mBuffers[0].mData;
    if (firstBuffer == NULL) {
        return noErr;
    }

    uint32_t readFrames = 0U;
    if (gRingReader != NULL) {
        readFrames = vm_ring_read(gRingReader, firstBuffer, inIOBufferFrameSize);
    }

    if (readFrames < inIOBufferFrameSize) {
        memset(firstBuffer + readFrames, 0, (size_t)(inIOBufferFrameSize - readFrames) * sizeof(float));
    }

    ioBufferList->mBuffers[0].mDataByteSize = inIOBufferFrameSize * sizeof(float);

    for (UInt32 i = 1U; i < ioBufferList->mNumberBuffers; ++i) {
        float* destination = (float*)ioBufferList->mBuffers[i].mData;
        if (destination == NULL) {
            continue;
        }
        memcpy(destination, firstBuffer, inIOBufferFrameSize * sizeof(float));
        ioBufferList->mBuffers[i].mDataByteSize = inIOBufferFrameSize * sizeof(float);
    }

    return noErr;
}

static OSStatus STDMETHODCALLTYPE VirtualMic_EndIOOperation(AudioServerPlugInDriverRef inDriver,
                                                            AudioObjectID inDeviceObjectID,
                                                            UInt32 inClientID,
                                                            UInt32 inOperationID,
                                                            UInt32 inIOBufferFrameSize,
                                                            const AudioServerPlugInIOCycleInfo* inIOCycleInfo) {
    (void)inDriver;
    (void)inDeviceObjectID;
    (void)inClientID;
    (void)inOperationID;
    (void)inIOBufferFrameSize;
    (void)inIOCycleInfo;
    return noErr;
}
