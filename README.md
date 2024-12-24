# Motoori, Online Error Database

Motoori, a reference to the Touhou Project character
[Kosuzu Motoori](https://en.touhouwiki.net/wiki/Kosuzu_Motoori),
is an online database for errors codes, messages, and symbolic names.

A live instance is available at [errors.dd86k.space](https://errors.dd86k.space/).

I made this because:
- I constantly have to lookup Windows error.
- I am curious what other codes are there.
- I don't want to constantly search on webpages and PDF files.

# Structure

This repo contains both the website platform and extractors.

- `extract`: Source for the extractor and archive packer
- `data`: Created by extractor, this is where data is written prior to archiving
- `pub`: Public files for HTTP server
- `source`: Source for HTTP server
- `views`: Pug template views for HTTP server

# Building the Database

Requirements:
- A recent D compiler. GDC might have issues compiling Vibe-d.
- A recent version of DUB.
- Windows for the `windows` extractor.
- Windows for the [Microsoft Error Lookup tool](https://docs.microsoft.com/en-us/windows/win32/debug/system-error-code-lookup-tool), used for symbolic names.
- Windows for the `crt` extractor.
- A Linux distro with the GNU environment for the `crt` extractor.
  - Ubuntu is a well supported choice.
- A Linux distro with the Musl environment for the `crt` extractor.
  - Alpine Linux is a well supported choice.

Suggestions:
- VirtualBox with a shared folders setup.

Steps:
1. Upgrade dependencies (as precaution): `dub upgrade`
2. Build the extractor for the platform: `dub build :extract`
3. Generate information for each platform: `extract --generate-all`
3. Windows: Run the MS error tool: `Err_6.4.5.exe /:outputtoCSV data\windows\symbolics.csv`
2. On Windows, run `dub run :windows`
3. On Windows, run `dub run :windows -- --headerdesc`
4. On Windows, run `dub run :crt`
5. On Windows, run `Err_6.4.5.exe /:outputtoCSV data\windows\symbolics.csv`
6. On a Glibc platform, run `dub run :crt`
7. On a Musl platform, run `dub run :crt`

Issues:
- `Invalid variable: DC`
  - Export variable `DC` to a compiler (e.g., `export DC=dmd`), or upgrade DUB

# Building the Site



