#!/bin/bash -eu

action_root="$(dirname "$(realpath "$BASH_SOURCE")")"

case "$INPUT_SHELL" in
'')
  device="$(sudo losetup -fP --show "$INPUT_IMAGE")"
  if sudo systemd-nspawn --quiet --image "${device}p2" which bash >/dev/null; then
    shell_command='bash -e {0}'
  else
    echo "Warning: Falling back to sh because bash wasn't found!" >&2
    shell_command='sh -e {0}'
  fi
  sudo losetup -d "$device"
  ;;
'bash')
  device="$(sudo losetup -fP --show "$INPUT_IMAGE")"
  if sudo systemd-nspawn --quiet --image "${device}p2" which bash >/dev/null; then
    shell_command='bash --noprofile --norc -eo pipefail {0}'
  else
    echo "Warning: Falling back to sh because bash wasn't found!" >&2
    shell_command='sh -e {0}'
  fi
  sudo losetup -d "$device"
  ;;
'python')
  shell_command='python {0}'
  ;;
'sh')
  shell_command='sh -e {0}'
  ;;
*)
  shell_command="$INPUT_SHELL"
  ;;
esac

boot_run_service=""
if [ "$INPUT_BOOT" == "true" ]; then
  boot_run_service="$action_root/default-boot-run.service"
  if [ ! -z "$INPUT_RUN_SERVICE" ]; then
    boot_run_service="$INPUT_RUN_SERVICE"
  fi
fi

echo "Running pinspawn.sh \"$INPUT_IMAGE\" \"$INPUT_USER\" \"$boot_run_service\" \"$INPUT_BOOT_PARTITION_MOUNT\" \"$INPUT_ARGS\" \"$shell_command\"..." >&2
echo "$INPUT_RUN" |
  "$action_root/pinspawn.sh" \
    "$INPUT_IMAGE" "$INPUT_USER" "$boot_run_service" "$INPUT_BOOT_PARTITION_MOUNT" "$INPUT_ARGS" "$shell_command"
