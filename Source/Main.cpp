#include <JuceHeader.h>

class LevelMeter final : public juce::Component
{
public:
    void setLevel(float newLevel)
    {
        level.store(juce::jlimit(0.0f, 1.0f, newLevel));
    }

    void paint(juce::Graphics& g) override
    {
        auto bounds = getLocalBounds().toFloat();
        g.fillAll(juce::Colours::black.withAlpha(0.6f));

        auto normalized = level.load();
        auto fillHeight = bounds.getHeight() * normalized;
        auto fillArea = bounds.removeFromBottom(fillHeight);

        g.setColour(juce::Colours::limegreen);
        g.fillRect(fillArea);

        g.setColour(juce::Colours::grey);
        g.drawRect(getLocalBounds());
    }

private:
    std::atomic<float> level { 0.0f };
};

struct LabeledSlider
{
    LabeledSlider(const juce::String& name)
    {
        label.setText(name, juce::dontSendNotification);
        label.setJustificationType(juce::Justification::centred);

        slider.setSliderStyle(juce::Slider::RotaryHorizontalVerticalDrag);
        slider.setTextBoxStyle(juce::Slider::TextBoxBelow, false, 70, 20);
    }

    void addTo(juce::Component& parent)
    {
        parent.addAndMakeVisible(label);
        parent.addAndMakeVisible(slider);
    }

    void setRange(double min, double max, double step, double value)
    {
        slider.setRange(min, max, step);
        slider.setValue(value);
    }

    juce::Label label;
    juce::Slider slider;
};

class MainComponent final : public juce::AudioAppComponent,
                            private juce::Slider::Listener,
                            private juce::Timer
{
public:
    MainComponent()
        : deviceSelector(deviceManager, 0, 2, 0, 2, true, true, true, false),
          inputGain("Input Gain"),
          threshold("Threshold"),
          ratio("Ratio"),
          attack("Attack"),
          release("Release"),
          makeupGain("Makeup"),
          eq1Freq("EQ1 Freq"),
          eq1Gain("EQ1 Gain"),
          eq1Q("EQ1 Q"),
          eq2Freq("EQ2 Freq"),
          eq2Gain("EQ2 Gain"),
          eq2Q("EQ2 Q"),
          eq3Freq("EQ3 Freq"),
          eq3Gain("EQ3 Gain"),
          eq3Q("EQ3 Q"),
          outputGain("Output Gain")
    {
        setAudioChannels(2, 2);

        addAndMakeVisible(deviceSelector);

        inputGain.setRange(-24.0, 24.0, 0.1, 0.0);
        threshold.setRange(-60.0, 0.0, 0.1, -18.0);
        ratio.setRange(1.0, 20.0, 0.1, 4.0);
        attack.setRange(1.0, 200.0, 1.0, 20.0);
        release.setRange(10.0, 500.0, 1.0, 100.0);
        makeupGain.setRange(-12.0, 24.0, 0.1, 0.0);

        eq1Freq.setRange(20.0, 20000.0, 1.0, 120.0);
        eq1Gain.setRange(-18.0, 18.0, 0.1, 0.0);
        eq1Q.setRange(0.1, 10.0, 0.1, 0.7);

        eq2Freq.setRange(20.0, 20000.0, 1.0, 1000.0);
        eq2Gain.setRange(-18.0, 18.0, 0.1, 0.0);
        eq2Q.setRange(0.1, 10.0, 0.1, 0.7);

        eq3Freq.setRange(20.0, 20000.0, 1.0, 6000.0);
        eq3Gain.setRange(-18.0, 18.0, 0.1, 0.0);
        eq3Q.setRange(0.1, 10.0, 0.1, 0.7);

        outputGain.setRange(-24.0, 24.0, 0.1, 0.0);

        addSliderGroup({ &inputGain, &threshold, &ratio, &attack, &release, &makeupGain,
                         &eq1Freq, &eq1Gain, &eq1Q,
                         &eq2Freq, &eq2Gain, &eq2Q,
                         &eq3Freq, &eq3Gain, &eq3Q,
                         &outputGain });

        addAndMakeVisible(inputMeter);
        addAndMakeVisible(outputMeter);

        startTimerHz(30);
        setSize(1100, 700);
    }

    ~MainComponent() override
    {
        shutdownAudio();
    }

    void prepareToPlay(int samplesPerBlockExpected, double sampleRate) override
    {
        juce::dsp::ProcessSpec spec;
        spec.sampleRate = sampleRate;
        spec.maximumBlockSize = static_cast<juce::uint32>(samplesPerBlockExpected);
        spec.numChannels = 2;

        processorChain.prepare(spec);
        currentSampleRate = sampleRate;

        updateAllParameters();
    }

    void getNextAudioBlock(const juce::AudioSourceChannelInfo& bufferToFill) override
    {
        auto& buffer = *bufferToFill.buffer;

        auto inputLevel = buffer.getRMSLevel(0, bufferToFill.startSample, bufferToFill.numSamples);
        if (buffer.getNumChannels() > 1)
            inputLevel = juce::jmax(inputLevel,
                                    buffer.getRMSLevel(1, bufferToFill.startSample, bufferToFill.numSamples));

        juce::dsp::AudioBlock<float> block(buffer);
        juce::dsp::ProcessContextReplacing<float> context(block);
        processorChain.process(context);

        auto outputLevel = buffer.getRMSLevel(0, bufferToFill.startSample, bufferToFill.numSamples);
        if (buffer.getNumChannels() > 1)
            outputLevel = juce::jmax(outputLevel,
                                     buffer.getRMSLevel(1, bufferToFill.startSample, bufferToFill.numSamples));

        inputMeterLevel.store(mapLevel(inputLevel));
        outputMeterLevel.store(mapLevel(outputLevel));
    }

    void releaseResources() override
    {
        processorChain.reset();
    }

    void paint(juce::Graphics& g) override
    {
        g.fillAll(juce::Colours::darkgrey.darker(0.6f));
    }

    void resized() override
    {
        auto bounds = getLocalBounds().reduced(10);
        auto header = bounds.removeFromTop(200);
        deviceSelector.setBounds(header.removeFromLeft(bounds.getWidth() - 120));

        auto meterArea = header.reduced(10);
        auto meterWidth = 40;
        inputMeter.setBounds(meterArea.removeFromLeft(meterWidth));
        meterArea.removeFromLeft(10);
        outputMeter.setBounds(meterArea.removeFromLeft(meterWidth));

        auto controls = bounds.reduced(10);
        auto rows = 4;
        auto columns = 4;

        auto cellWidth = controls.getWidth() / columns;
        auto cellHeight = controls.getHeight() / rows;

        int index = 0;
        for (auto* control : sliderControls)
        {
            auto row = index / columns;
            auto col = index % columns;
            auto cell = juce::Rectangle<int>(
                controls.getX() + col * cellWidth,
                controls.getY() + row * cellHeight,
                cellWidth,
                cellHeight);

            control->label.setBounds(cell.removeFromTop(22));
            control->slider.setBounds(cell.reduced(10));
            ++index;
        }
    }

private:
    using ProcessorChain = juce::dsp::ProcessorChain<
        juce::dsp::Gain<float>,
        juce::dsp::Compressor<float>,
        juce::dsp::Gain<float>,
        juce::dsp::IIR::Filter<float>,
        juce::dsp::IIR::Filter<float>,
        juce::dsp::IIR::Filter<float>,
        juce::dsp::Gain<float>>;

    void timerCallback() override
    {
        inputMeter.setLevel(inputMeterLevel.load());
        outputMeter.setLevel(outputMeterLevel.load());
        inputMeter.repaint();
        outputMeter.repaint();
    }

    void sliderValueChanged(juce::Slider* slider) override
    {
        if (slider == &inputGain.slider)
            processorChain.get<0>().setGainDecibels(static_cast<float>(slider->getValue()));
        else if (slider == &threshold.slider)
            processorChain.get<1>().setThreshold(static_cast<float>(slider->getValue()));
        else if (slider == &ratio.slider)
            processorChain.get<1>().setRatio(static_cast<float>(slider->getValue()));
        else if (slider == &attack.slider)
            processorChain.get<1>().setAttack(static_cast<float>(slider->getValue()));
        else if (slider == &release.slider)
            processorChain.get<1>().setRelease(static_cast<float>(slider->getValue()));
        else if (slider == &makeupGain.slider)
            processorChain.get<2>().setGainDecibels(static_cast<float>(slider->getValue()));
        else if (slider == &outputGain.slider)
            processorChain.get<6>().setGainDecibels(static_cast<float>(slider->getValue()));
        else
            updateEqFilters();
    }

    void updateEqFilters()
    {
        if (currentSampleRate <= 0.0)
            return;

        auto eq1 = juce::dsp::IIR::Coefficients<float>::makePeakFilter(
            currentSampleRate,
            static_cast<float>(eq1Freq.slider.getValue()),
            static_cast<float>(eq1Q.slider.getValue()),
            juce::Decibels::decibelsToGain(static_cast<float>(eq1Gain.slider.getValue())));

        auto eq2 = juce::dsp::IIR::Coefficients<float>::makePeakFilter(
            currentSampleRate,
            static_cast<float>(eq2Freq.slider.getValue()),
            static_cast<float>(eq2Q.slider.getValue()),
            juce::Decibels::decibelsToGain(static_cast<float>(eq2Gain.slider.getValue())));

        auto eq3 = juce::dsp::IIR::Coefficients<float>::makePeakFilter(
            currentSampleRate,
            static_cast<float>(eq3Freq.slider.getValue()),
            static_cast<float>(eq3Q.slider.getValue()),
            juce::Decibels::decibelsToGain(static_cast<float>(eq3Gain.slider.getValue())));

        *processorChain.get<3>().coefficients = *eq1;
        *processorChain.get<4>().coefficients = *eq2;
        *processorChain.get<5>().coefficients = *eq3;
    }

    void updateAllParameters()
    {
        processorChain.get<0>().setGainDecibels(static_cast<float>(inputGain.slider.getValue()));
        processorChain.get<1>().setThreshold(static_cast<float>(threshold.slider.getValue()));
        processorChain.get<1>().setRatio(static_cast<float>(ratio.slider.getValue()));
        processorChain.get<1>().setAttack(static_cast<float>(attack.slider.getValue()));
        processorChain.get<1>().setRelease(static_cast<float>(release.slider.getValue()));
        processorChain.get<2>().setGainDecibels(static_cast<float>(makeupGain.slider.getValue()));
        processorChain.get<6>().setGainDecibels(static_cast<float>(outputGain.slider.getValue()));
        updateEqFilters();
    }

    void addSliderGroup(std::initializer_list<LabeledSlider*> sliders)
    {
        for (auto* control : sliders)
        {
            control->addTo(*this);
            control->slider.addListener(this);
            sliderControls.push_back(control);
        }
    }

    static float mapLevel(float linear)
    {
        auto db = juce::Decibels::gainToDecibels(linear, -60.0f);
        return juce::jlimit(0.0f, 1.0f, (db + 60.0f) / 60.0f);
    }

    juce::AudioDeviceSelectorComponent deviceSelector;
    LevelMeter inputMeter;
    LevelMeter outputMeter;

    LabeledSlider inputGain;
    LabeledSlider threshold;
    LabeledSlider ratio;
    LabeledSlider attack;
    LabeledSlider release;
    LabeledSlider makeupGain;
    LabeledSlider eq1Freq;
    LabeledSlider eq1Gain;
    LabeledSlider eq1Q;
    LabeledSlider eq2Freq;
    LabeledSlider eq2Gain;
    LabeledSlider eq2Q;
    LabeledSlider eq3Freq;
    LabeledSlider eq3Gain;
    LabeledSlider eq3Q;
    LabeledSlider outputGain;

    std::vector<LabeledSlider*> sliderControls;

    ProcessorChain processorChain;
    double currentSampleRate = 0.0;

    std::atomic<float> inputMeterLevel { 0.0f };
    std::atomic<float> outputMeterLevel { 0.0f };

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR(MainComponent)
};

class MainWindow final : public juce::DocumentWindow
{
public:
    MainWindow(juce::String name)
        : DocumentWindow(std::move(name),
                         juce::Desktop::getInstance().getDefaultLookAndFeel()
                             .findColour(juce::ResizableWindow::backgroundColourId),
                         DocumentWindow::allButtons)
    {
        setUsingNativeTitleBar(true);
        setContentOwned(new MainComponent(), true);
        setResizable(true, true);
        centreWithSize(getWidth(), getHeight());
        setVisible(true);
    }

    void closeButtonPressed() override
    {
        juce::JUCEApplication::getInstance()->systemRequestedQuit();
    }
};

class MacAudioApplication final : public juce::JUCEApplication
{
public:
    MacAudioApplication() = default;

    const juce::String getApplicationName() override { return "macaudio"; }
    const juce::String getApplicationVersion() override { return "0.1.0"; }
    bool moreThanOneInstanceAllowed() override { return true; }

    void initialise(const juce::String&) override
    {
        mainWindow = std::make_unique<MainWindow>(getApplicationName());
    }

    void shutdown() override
    {
        mainWindow.reset();
    }

    void systemRequestedQuit() override
    {
        quit();
    }

    void anotherInstanceStarted(const juce::String&) override
    {
    }

private:
    std::unique_ptr<MainWindow> mainWindow;
};

START_JUCE_APPLICATION(MacAudioApplication)
