#!/usr/bin/env bash
# Запускает команду и при ошибке выводит хвост её вывода как аннотации GitHub (их видно без доступа к полным логам).
set -o pipefail
"$@" 2>&1 | tee .run.log
code=${PIPESTATUS[0]}
if [ "$code" != 0 ]; then
  tail -n 45 .run.log | sed 's/\r$//' | grep -v '^\s*$' | while IFS= read -r l; do echo "::error::${l//%/%25}"; done
fi
exit "$code"
