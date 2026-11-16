# Capabilities

## Working now (native unless noted)

| From                                                   | To                                                          | Engine                          | Notes                                                  |
| ------------------------------------------------------ | ----------------------------------------------------------- | ------------------------------- | ------------------------------------------------------ |
| HEIC, JPEG, PNG, TIFF, BMP, GIF, WebP, AVIF, ICNS, ICO | JPEG, PNG, TIFF, BMP, GIF, HEIC, WebP, AVIF, ICNS, ICO, PDF | ImageIO, ImageMagick fallback   | WebP encode uses `magick` when ImageIO cannot write it |
| PDF | any image format + text | PDFKit | Every page at 200 dpi as `Name.ext`, `Name 2.ext`, …; `+pageN` for one page, `+dpi` to change resolution |
| SVG, SVGZ | any image format | AppKit | Drawn as vectors, 2048 px on the long side unless a width or height is given |
| any image | PDF | Core Graphics | One page fitted to the system paper size, stored as JPEG |
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
| Camera RAW (DNG, CR2, CR3, NEF, ARW, RAF, ORF, RW2, PEF, SR2), PSD, TGA, JPEG XL | any writable image format | ImageIO | RAW and JPEG XL are read-only |
| any readable image | TGA, PSD | ImageIO | PSD is written flattened |
| DOC, ODT | PDF, TXT, RTF, HTML, DOCX, DOC, ODT | TextKit | Text and basic styling |
| Folder, ZIP, TAR, TGZ, TBZ2, TXZ, 7z, RAR/CBR | ZIP, TAR, TGZ, TBZ2, TXZ, 7z, CBZ, CBT | ditto / bsdtar | RAR is read-only |
| ZIP | NPZ | native | Each file becomes a uint8 NumPy array; a zip of `.npy` files is packed as-is |
| ZIP | PT, PTH | native | `torch.load(..., weights_only=False)` returns a dict of the original file bytes |
| NPZ, PT | ZIP | native | The container is already a zip, so this copies the bytes |
| MP3, FLAC, WAV, AIFF, CAF, M4A | FLAC, WAV, AIFF, CAF, M4A | Core Audio | No ffmpeg needed; MP3 encode still needs ffmpeg |
| OBJ, STL, PLY, USDA, USDC, USDZ | OBJ, STL, PLY, USDA, USDC | Model I/O | Geometry only; USDZ is read-only |
| DER ↔ PEM                                              |                                                             | native                          |                                                        |
| SRT ↔ VTT ↔ TXT                                        |                                                             | native                          |                                                        |
| JPEG, PNG, TIFF, … | JPEG 2000, OpenEXR, Netpbm PPM, ASTC | ImageIO | ASTC is a GPU texture block |
| CSV, TSV, JSON, YAML, XLSX, JSONL | SQLite and back | sqlite3 | Every user table; several tables become one JSON object or a `table` column |
| JSON Lines | CSV, JSON, YAML, XLSX, SQLite | native | One JSON value per line |
| GPX, KML, GeoJSON, CSV, JSON | each other | native | Points keep name, elevation and time |
| vCard | CSV, JSON and back | native | Name, email, phone, organization |
| ICS | CSV, JSON and back | native | Summary, start, end, location |
| EML, EMLX | PDF, TXT, HTML, DOCX, RTF | native | Headers plus the text body; EMLX is read-only |
| OPML | the document formats, and back | native | Nested outline titles |
| any file | Base64 and back | native | `photo.png` ↔ `photo.b64` |
| text file | PNG, JPEG, PDF, … with `+qr` | Core Image | The file's text becomes a QR code |
| image or PDF with `+qr` | TXT | Vision | QR codes and common barcodes |
| TTF, OTF | any image | Core Text | A preview of the font, not a new font file |
| INI, CFG, ENV, Java properties, Apple strings | JSON, YAML, TOML, PLIST, XML and each other | native | Sections stay nested; values stay text where the format has no types |
| webloc, URL | TXT, JSON and each other | native | The link itself |
| RSS, Atom | JSON and each other | native | Title, link, summary, date |
| TCX | GPX, KML, GeoJSON, CSV, JSON | native | Garmin track points |
| M3U, M3U8 | JSON, TXT | native | Playlist entries |
| LRC | SRT, VTT, TXT | native | Timed lyrics |
| NMEA, IGC | GPX, KML, GeoJSON, CSV, JSON, TCX | native | GPS and flight-log fixes |
| BibTeX | JSON, CSV and back | native | Citation, title, author, year |
| LDIF | JSON, CSV and back | native | LDAP directory entries |
| CUE | M3U, JSON, TXT | native | CD track list |
| SBV, SAMI | SRT, VTT, LRC, TXT | native | YouTube and SAMI captions |
| GIMP palette, HEX, CLR, CSS | each other and JSON | native | Color lists, including macOS .clr |
| .editorconfig | the config formats | native | Read as INI |

## Registered, not converted

Formats such as Pages, Numbers, Keynote, PPTX, XLS, e-books, WOFF, glTF/FBX models, and LibreOffice-only documents are listed in the registry and return `unsupportedConversion` until a real encoder exists. TTF and OTF can be rendered to an image; they are not rewritten as another font.

## Filename grammar

Implemented and unit-tested: quality, min, size caps, nometa, width/height, 480p–4K, crop, smartcrop, trim, at, speed, mute, normalize, mono, reverse, rotate, flips, nobg, lossless, bitrate, dpi, pages, codecs, fps, gray, loop, ocr, transcribe, lang, qr, multi-output, `!`, trailing `+`, `.folder,zip`.
