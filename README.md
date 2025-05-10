# Flutter Voice Dataset Recorder

[![License: CC0](https://img.shields.io/badge/License-CC0-red.svg)](https://creativecommons.org/publicdomain/zero/1.0/)
[![Flutter](https://img.shields.io/badge/Flutter-%3E%3D3.0.0-blue)](https://flutter.dev)

Flutter application developed for creating professional audio datasets. Allows you to create datasets for TTS (Text to Speech) systems by recording texts read from CSV files.

## Features

- Loading text lists in CSV format
- High-quality audio recording for each text
- Automatic metadata file creation
- Listening and checking recordings
- Speaker and grammar support
- Continuing where you left off

## Installation

1. Install Flutter SDK (3.0.0 or later)
2. Clone this project:
```bash
git clone https://github.com/azmisahin-mobile/flutter-voice-dataset-recorder.git
```
3. Install dependencies:
```bash
flutter pub get
```
4. Run:
```bash
flutter run
```

## Usage
1. Copy metadata.csv file to /storage/emulated/0/Download/MyVoiceDataset/
2. Start the application
3. Use "Save" button to record
4. Collect all your recordings in one file with "Create Metadata File" button

## CSV Format

Example CSV file format (with | separated):
```csv
id|text|speaker|language
1|This is an example sentence|speaker1|tr-TR
2|Second recording example|speaker2|en-UK
```
