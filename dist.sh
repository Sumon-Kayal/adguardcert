#!/bin/bash
set -e

UPDATE_BINARY_URL="https://raw.githubusercontent.com/topjohnwu/Magisk/master/scripts/module_installer.sh"

mkdir -p ./module/META-INF/com/google/android
curl -fsSL "${UPDATE_BINARY_URL}" -o ./module/META-INF/com/google/android/update-binary
echo "#MAGISK" > ./module/META-INF/com/google/android/updater-script

VERSION=$(sed -ne "s/version=\(.*\)/\1/gp" ./module/module.prop)
NAME=$(sed -ne "s/id=\(.*\)/\1/gp" ./module/module.prop)

rm -f "${NAME}-${VERSION}.zip"
python3 -c "
import os
import zipfile
import sys

output_file = '${NAME}-${VERSION}.zip'
module_dir = './module'

with zipfile.ZipFile(output_file, 'w', zipfile.ZIP_DEFLATED) as zipf:
    for root, dirs, files in os.walk(module_dir):
        # Skip hidden directories
        dirs[:] = [d for d in dirs if not d.startswith('.')]
        for file in files:
            # Skip hidden files
            if file.startswith('.'):
                continue
            file_path = os.path.join(root, file)
            arcname = os.path.relpath(file_path, module_dir)
            zipf.write(file_path, arcname)
"
