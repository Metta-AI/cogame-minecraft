## Emits the JS wire-constants block (src/minecraft/wire_constants.nim) on stdout.
## The static replay-viewer bundle can't run the server's compile-time
## splice, so Dockerfile.replay-viewer runs this to write
## dist/wire_constants.js and injects a <script src> for it into both dist
## HTML pages — same constants, same source, different delivery.
import ../src/minecraft/wire_constants

echo WireConstantsJs
