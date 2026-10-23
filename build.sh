#!/bin/sh
# 把 module/ 目录打包成可刷入的 zip
set -e
NAME="smart5g"
VER=$(sed -n 's/^version=//p' module/module.prop)
OUT="${NAME}-${VER}.zip"
rm -f "$OUT"
cd module
zip -r "../$OUT" . -x '*.bak*' -x '*.zip'
cd ..
echo "built: $OUT"
ls -lh "$OUT"
