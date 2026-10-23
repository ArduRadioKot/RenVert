# Capabilities

## Working now (native unless noted)

| From                                                   | To                                                          | Engine                          | Notes                                                  |
| ------------------------------------------------------ | ----------------------------------------------------------- | ------------------------------- | ------------------------------------------------------ |
| HEIC, JPEG, PNG, TIFF, BMP, GIF, WebP, AVIF, ICNS, ICO | JPEG, PNG, TIFF, BMP, GIF, HEIC, WebP, AVIF, ICNS, ICO, PDF | ImageIO, ImageMagick fallback   | WebP encode uses `magick` when ImageIO cannot write it |
| PDF                                                    | PNG/JPEG/TIFF + text                                        | PDFKit                          | First page unless `+pageN`                             |
| DOCX                                                   | PDF, TXT, RTF, HTML, DOCX                                   | TextKit + OOXML                 | Layout is paragraph-accurate, not print-accurate       |
| TXT, Markdown, HTML, RTF                               | PDF, DOCX, HTML, RTF, TXT                                   | TextKit                         | Markdown is treated as text                            |
| JSON, YAML, PLIST, XML, TOML                           | each other                                                  | native                          | YAML/TOML are practical subsets                        |
| CSV, TSV, XLSX, JSON                                   | CSV, TSV, XLSX, JSON, YAML                                  | OOXML / native                  | XLS / Numbers / Parquet not implemented                |
| Folder                                                 | ZIP, TAR, TGZ, CBZ, CBT                                     | ditto / tar                     | Path traversal is rejected on extract                  |
| ZIP/TAR/TGZ/CBZ/CBT                                    | ZIP/TAR/TGZ                                                 | ditto / tar                     |                                                        |
| MOV, MP4                                               | MP4, MOV, M4A                                               | AVFoundation                    |                                                        |
| WAV, AIFF, CAF, M4A                                    | M4A, WAV, CAF, AIFF                                         | AVFoundation                    |                                                        |
| WAV / video                                            | MP3, FLAC, OGG, MKV, WebM, GIF                              | ffmpeg if present               | Honest failure if ffmpeg is missing                    |
| Video                                                  | still image                                                 | AVFoundation / ffmpeg           | `+atTIME`                                              |
| Video                                                  | SRT/VTT/TXT                                                 | ffmpeg extract or `+transcribe` |                                                        |
| Image / PDF                                            | TXT / searchable PDF                                        | Vision OCR                      | `+ocr`, `+lang_`                                       |
| Audio / video                                          | TXT / SRT / VTT                                             | Speech                          | On-device when the locale supports it                  |
| DER ↔ PEM                                              |                                                             | native                          |                                                        |
| SRT ↔ VTT ↔ TXT                                        |                                                             | native                          |                                                        |

## Registered, not converted

RAW camera files can often be _decoded_ by ImageIO into another image. Formats such as JXL, Pages, Numbers, Keynote, PPTX, XLS, e-books, fonts, 3D models, 7z, RAR/CBR, and LibreOffice-only documents are listed in the registry and return `unsupportedConversion` until a real encoder exists.

## Filename grammar

Implemented and unit-tested: quality, min, size caps, nometa, width/height, 480p–4K, crop, smartcrop, trim, at, speed, mute, normalize, mono, reverse, rotate, flips, nobg, lossless, bitrate, dpi, pages, codecs, fps, gray, loop, ocr, transcribe, lang, multi-output, `!`, trailing `+`, `.folder,zip`.
