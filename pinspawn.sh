#!/bin/bash -eux

mount_image() {
  local image
  image="$1"
  local sysroot
  sysroot="${2:-}"

  echo "Mounting $image..." 1>&2
  device="$(losetup -fP --show "$image")"
  echo "Mounted to $device!" 1>&2

  if [ -z "$sysroot" ]; then
    echo "$device"
    return 0
  fi

  echo "Mounting $device..." 1>&2
  mkdir -p "$sysroot"
  sudo mount "${device}p2" "$sysroot" 1>&2
  sudo mount "${device}p1" "$sysroot/boot" 1>&2
  echo "Mounted to $sysroot!" 1>&2

  echo $device
}

unmount_image() {
  local device
  device="$1"
  local sysroot
  sysroot="${2:-}"

  if [ ! -z "$sysroot" ]; then
    echo "Unmounting $sysroot..." 1>&2
    sudo umount "$sysroot/boot"
    sudo umount "$sysroot"
  fi

  echo "Unmounting $device..." 1>&2
  sudo e2fsck -p -f "${device}p2"
  sudo losetup -d "$device"
}

image="$1" # e.g. "rpi-os-image.img"
boot_run_service="$2" # e.g. "/path/to/default-boot-run.service"
args="${3:-}" # e.g. "--bind /path/in/host:/path/in/container"
shell_command="${4:-}" # e.g. "su - pi bash -e {0}"

sysroot="$(sudo mktemp -d --tmpdir=/mnt sysroot.XXXXXXX)"
device="$(mount_image "$image" "$sysroot")"

tmp_script="$(sudo mktemp --tmpdir="$sysroot/tmp" pinspawn-script.XXXXXXX)"
cat > "$tmp_script"
shell_script_command="$(echo "$shell_command" | sed "s~{0}~$tmp_script~")"

if [ ! -z "$boot_run_service" ]; then
  args="--boot $args"

  boot_tmp_script="$(sudo mktemp --tmpdir="$sysroot/usr/bin" pinspawn-script.XXXXXXX)"
  sudo cp "$tmp_script" "$boot_tmp_script"

  boot_tmp_service="$(sudo mktemp --tmpdir="$sysroot/etc/systemd/system" --suffix="@.service" pinspawn-XXXXXXX)"
  sudo cp "$boot_run_service" "$boot_tmp_service"
  sudo awk -v r="$shell_script_command" -e 'gsub(/{0}/, r)' $boot_tmp_service

  boot_tmp_result="$(sudo mktemp --tmpdir="$sysroot/var/lib" pinspawn-status.XXXXXXX)"

  boot_tmp_service_instance="$boot_tmp_service@$(systemd-escape "$boot_tmp_result")"
  sudo systemd-nspawn --directory "$sysroot" systemctl enable "$boot_tmp_service_instance"
else
  args="$args $shell_script_command"
fi

sudo systemd-nspawn --directory "$sysroot" $args

if [ ! -z "$boot_run_service" ]; then
  sudo systemd-nspawn --directory "$sysroot" systemctl disable "$boot_tmp_service_instance"

  if [ ! -f "$boot_tmp_result" ]; then
    echo "Error: $boot_run_service_instance did not store a result indicating success/failure!"
    exit 1
  elif [ "$(cat "$boot_tmp_result")" != "0" ]; then
    result="$(cat "$boot_tmp_result")"
    echo "Error: $boot_run_service_instance failed while running $shell_script_command: $result"
    case "$result" in
      '' | *[!0-9]*)
        exit 1
        ;;
      *)
        exit "$result"
        ;;
    esac
  fi
  sudo rm -f "$boot_tmp_result"

  sudo rm -f "$boot_tmp_service"

  sudo rm -f "$boot_tmp_script"
fi

sudo rm -f "$tmp_script"

unmount_image "$device" "$sysroot"
