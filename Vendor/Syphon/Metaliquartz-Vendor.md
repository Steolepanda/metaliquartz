# Vendored Syphon Framework

- Upstream: https://github.com/Syphon/Syphon-Framework
- Commit: `71351d4b484cd2d1917867f7846a5cdca724552d`
- License: `License.txt` in this directory
- Local modification: removed the deprecated `kIOSurfaceIsGlobal` creation property. Modern
  IOSurfaces can still be shared through the IOSurface ID used by Syphon, so publishing and lookup
  behavior are unchanged while the macOS deprecation warning is eliminated.

Metaliquartz links the official `Syphon.framework` target and its application code uses only
`SyphonMetalClient`, `SyphonMetalServer`, and server discovery metadata required to select a Metal
source. OpenGL client/server APIs are not used by Metaliquartz.
