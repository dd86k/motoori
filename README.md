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

- `extractcode`: Source for the extractor and archive packer
- `data`: Used for loading data
- `pub`: Public files for HTTP server
- `source`: Source for HTTP server
- `views`: Pug template views for HTTP server

# Building the Database

Requirements:
- A recent D compiler. GDC might have issues compiling vibe-d.
- A recent version of DUB.
- Windows install for headers and module entries.
- [Microsoft Error Lookup tool](https://docs.microsoft.com/en-us/windows/win32/debug/system-error-code-lookup-tool).
- A Linux distro with the GNU environment for the `crt` extractor.
  - Ubuntu is a well supported choice.
- A Linux distro with the Musl environment for the `crt` extractor.
  - Alpine Linux is a well supported choice.

Suggestions:
- VirtualBox with a shared folders setup.

Steps:
1. Upgrade dependencies (as precaution): `dub upgrade`
2. Build the extractor for the platform: `dub build :extract`
3. Generate information for current C runtime: `extract --generate-crt`
4. Windows: Run the MS error tool: `Err_6.4.5.exe /:outputtoCSV headers.csv`
5. To build the symbolic entries, run `extract --generate-windows-headers=headers.csv`
6. To build the modules entries, run `extract --generate-windows-modules`

Should have most things. Do note that different versions of Windows will have
different module versions.

Issues:
- `Invalid variable: DC`
  - Export variable `DC` to a compiler (e.g., `export DC=dmd`), or upgrade DUB

# Building the Site

Usually just `dub` to build and run a debug build.
`dub build -b release --compiler=ldc2` for releases.
