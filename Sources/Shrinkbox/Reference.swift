import Foundation

enum Reference {
    /// The pipeline language, written for people and for AI agents.
    static let pipelineGuide = """
    # Shrinkbox pipelines

    A pipeline is an ordered list of steps that transform image, video, PDF and audio files.
    Steps are separated by `->` and run left to right: `crop(width: 1600) -> convert(to: webp)`.
    A step is `name(key: value, key: value)`; steps without parameters are bare (`removeAudio`, `stripExif`).
    Quote text values: `move(to: "~/Pictures/%y/")`. A step that does not apply to a file's kind is skipped.

    ## Running

    - `shrinkbox pipeline run '<steps>' files…` runs exactly the steps written. No optimisation is added.
    - A saved pipeline is optimised first unless it is saved with `--skip-optimisation`.
    - `shrinkbox pipeline add [--file-type image|video|pdf|audio] [--skip-optimisation] [--force] <name> '<steps>'`
    - `shrinkbox pipeline attach '<name or steps>' --source <clipboard|dropZone|folder> --type <image|video|pdf|audio>`
      runs it by itself on every new file of that type from the source (a folder is watched).
    - `shrinkbox pipeline preset add '<name>' '<pipeline>' [--type T] [--icon SYMBOL]` makes a drop zone preset.

    ## Steps

    Processing (consecutive in-place steps share a single encoding pass):
    - `optimise(encoder, compression, adaptive, dpi, location)` — images, PDFs and audio: encoder medium, aggressive or
      lossless; video: fast (hardware), slowHighQuality (software) or visuallyLossless. `compression`: 5 (best quality) to 100
      (smallest) or adaptive. `dpi` is for PDFs: 300 leaves images alone, 150 suits reading, 72 screens, 48 smallest.
    - `downscale(factor, location)` — factor 0 to 1 keeps the aspect ratio. For audio it lowers the bitrate.
    - `lowerBitrate(kbps, location)` — audio only; never raises a bitrate.
    - `convert(to, location)` — images: webp avif heic jxl jpeg png gif; video: mp4 hevc x265 av1 webm gif; audio: m4a mp3 ogg
      flac wav aiff. Converting to the format a file already has does nothing. Default location: sameFolder.
    - `crop(width, height, longEdge, aspectRatio, smartCrop, location)` — exact pixels, the long side, or a shape like 16:9.
      `smartCrop: true` centres on what the eye goes to.
    - `targetSize(size, location)` — compresses until the file fits: 500KB, 10MB, 25MB. Do not add `optimise` after it.
    - `extractPagesAsImages(format, quality, location)` — PDF pages to jpeg or png; quality low, medium or high.
    - `stripExif` — removes EXIF and GPS metadata. `watermark(image, position, opacity, scale, location)`.
    - Video and audio: `removeAudio`, `changeSpeed(factor, frames)` (frames: keep or drop), `capFps(fps)`, `normalize(lufs)`.

    Filters: `if(...)` continues only when the condition holds, `ifNot(...)` only when it does not; there is no else.
    Keys (all must hold): regex, types (`jpeg png`), nameContains, nameIs, fileSizeGreaterThan, fileSizeLowerThan, minFileSize,
    widthGreaterThan, widthLowerThan, heightGreaterThan, heightLowerThan, minResolution (`640x480`), dpiGreaterThan,
    dpiLowerThan, copiedBy (clipboard only). To give two kinds different treatment, make two pipelines.

    File operations: `copy(to)`, `move(to)`, `rename(to)`, `delete(path)` (`delete(path: "sourceFile")` removes the input).
    Actions: `runScript(path)` or `runScript(code)` (the file is `$1` and `$SHRINKBOX_INPUT_FILE`; a printed path replaces the
    file), `runShortcut(name)`, `copyToClipboard(format: path|imageData|markdown, relativeTo)`, `fork(location)`,
    `openWith(app)`, `shelveWith(app)`, `uploadWith(app)`.

    ## Locations and templates

    `location`: inPlace (default for most steps), sameFolder, temporaryFolder, or a path template.
    Tokens: `%f` name, `%e` extension, `%P` parent folder, `%F` full path, `%y %m %n %d %w` date, `%H %M %S %p` time,
    `%r` random letters, `%i` counter. `$1`, `$2`… are capture groups of a preceding `if(regex: …)`.

    ## Examples

    - For the web: `optimise -> convert(to: webp)`
    - Under 10MB: `targetSize(size: 10MB)`
    - Video to 1080p: `crop(width: 1920) -> optimise(encoder: slowHighQuality)`
    - Video to GIF: `crop(longEdge: 800) -> convert(to: gif)`
    - 2× silent screencast: `changeSpeed(factor: 2.0, frames: drop) -> removeAudio -> optimise(encoder: fast)`
    - Audio to MP3 at 128k: `convert(to: mp3) -> lowerBitrate(kbps: 128)`
    - Sort screenshots: `if(regex: "^screen ?shot") -> optimise -> move(to: "~/Pictures/Screenshots/%y/%m/")`
    """
}
