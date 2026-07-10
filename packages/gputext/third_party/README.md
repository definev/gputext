# Third-party dependencies

## harfbuzz (git submodule)

HarfBuzz is pulled in as a git submodule pinned to a release tag
(currently 14.2.1). After cloning this repo, run:

```sh
git submodule update --init
```

It is built as a C++ amalgamation (`src/harfbuzz.cc`) by
`packages/gputext/hook/build.dart` with no FreeType/CoreText/DirectWrite
backends — font bytes are fed through `hb_blob_create` / `hb_face_create`
from Dart.

To update to a newer release:

```sh
git -C packages/gputext/third_party/harfbuzz fetch --tags
git -C packages/gputext/third_party/harfbuzz checkout <tag>
git add packages/gputext/third_party/harfbuzz
```

License: MIT-style ("Old MIT"), see `harfbuzz/COPYING`.
