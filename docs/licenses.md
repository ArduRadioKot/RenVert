# Licenses

Renvert source in this repository is original and intended for local use with the project.

## System frameworks

ImageIO, Core Image, Core Graphics, AVFoundation, VideoToolbox, PDFKit, Vision, Speech, UniformTypeIdentifiers, AppKit, SwiftUI, SMAppService, and FSEvents are Apple system frameworks. They ship with macOS.

## Bundled or discovered tools

| Tool                                               | Typical license                  | How Renvert uses it                                                                                         |
| -------------------------------------------------- | -------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `/usr/bin/ditto`, `/usr/bin/tar`, `/usr/bin/unzip` | Apple system                     | Archives; arguments are arrays, never a shell string                                                        |
| ffmpeg / ffprobe                                   | LGPL/GPL depending on build      | Optional. Copied into `Contents/Resources/bin` only if already installed. Not redistributed from this repo. |
| ImageMagick (`magick`)                             | Apache-2.0 / ImageMagick license | Optional discovery only                                                                                     |
| Pandoc                                             | GPL-2.0                          | Optional discovery only                                                                                     |
| LibreOffice (`soffice`)                            | MPL-2.0                          | Optional discovery only                                                                                     |

If you ship a build that includes ffmpeg, you must comply with that ffmpeg build’s license (often LGPL, GPL if `--enable-gpl`). This project does not vendor ffmpeg sources.
