cmake_minimum_required(VERSION 3.15)
project(macaudio VERSION 0.1.0)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_subdirectory(external/JUCE)

juce_add_gui_app(macaudio
    PRODUCT_NAME "macaudio"
)

target_sources(macaudio
    PRIVATE
        Source/Main.cpp
)

target_compile_definitions(macaudio
    PRIVATE
        JUCE_WEB_BROWSER=0
        JUCE_USE_CURL=0
)

target_link_libraries(macaudio
    PRIVATE
        juce::juce_audio_utils
        juce::juce_dsp
    PUBLIC
        juce::juce_recommended_config_flags
        juce::juce_recommended_lto_flags
        juce::juce_recommended_warning_flags
)
