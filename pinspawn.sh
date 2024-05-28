#!/bin/bash -eux

mount_image() {
  local image
  image="$1"
  local sysroot
  sysroot="${2:-}"

  echo "Mounting $image..." 1>&2
  device="$(sudo losetup -fP --show "$image")"
  if [ -z "$device" ]; then
    echo "Error: couldn't mount $image!"
    return 1
  fi
  echo "Mounted to $device!" 1>&2

  if [ -z "$sysroot" ]; then
    echo "$device"
    return 0
  fi

  echo "Mounting $device..." 1>&2
  sudo mkdir -p "$sysroot"
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
user="$2" # e.g. "pi"
boot_run_service="$3" # e.g. "/path/to/default-boot-run.service"
args="$4" # e.g. "--bind /path/in/host:/path/in/container"
shell_command="$5" # e.g. "bash -e {0}"

sysroot="$(sudo mktemp -d --tmpdir=/mnt sysroot.XXXXXXX)"
device="$(mount_image "$image" "$sysroot")"

# Note: we can't use `/tmp` because it will be remounted by the container
tmp_script="$(sudo mktemp --tmpdir="$sysroot/usr/bin" pinspawn-script.XXXXXXX)"
# Note: this command reads & processes stdin:
sudo tee "$tmp_script" > /dev/null
sudo chmod a+x "$tmp_script"
container_tmp_script="${tmp_script#"$sysroot"}"
sudo systemd-nspawn --directory "$sysroot" \
  chown "$user" "$container_tmp_script"
shell_script_command="$(\
  printf '%s' "$shell_command" | awk -v r="$container_tmp_script" -e 'gsub(/{0}/, r)' \
)"
if [ -z "$shell_script_command" ]; then
  # shell_command didn't have {0}, so we'll just use it verbatim:
  shell_script_command="$shell_command"
fi

if [ ! -z "$user" ]; then
  args="--user $user $args"
fi
if [ ! -z "$boot_run_service" ]; then
  echo "Preparing to run commands during container boot..."
  args="--boot $args"

  boot_tmp_script="$(sudo mktemp --tmpdir="$sysroot/usr/bin" pinspawn-script.XXXXXXX)"
  sudo cp "$tmp_script" "$boot_tmp_script"
  sudo chmod a+x "$boot_tmp_script"
  sudo systemd-nspawn --directory "$sysroot" \
    chown "$user" "${boot_tmp_script#"$sysroot"}"

  boot_tmp_service="$(\
    sudo mktemp --tmpdir="$sysroot/etc/systemd/system" --suffix="@.service" pinspawn_XXXXXXX \
  )"
  while IFS="" read -r line || [ -n "$line" ]; do
    interpolated="$(printf '%s' "$line" | awk -v r="$line" -e 'gsub(/{0}/, r)')"
    if [ -z "$interpolated" ]; then
      # line didn't have {0}, so we'll just use it verbatim:
      interpolated="$line"
    fi
    printf '%s' "$interpolated" | sudo tee --append "$boot_tmp_service"
  done < "$boot_run_service"
  echo "Boot run service $boot_tmp_service:"
  sudo cat "$boot_tmp_service"

  boot_tmp_result="$(sudo mktemp --tmpdir="$sysroot/var/lib" pinspawn_status.XXXXXXX)"

  boot_tmp_service_instance="${boot_tmp_service%'@.service'}@$(systemd-escape "$boot_tmp_result").service"
  sudo systemd-nspawn --directory "$sysroot" \
    systemctl enable "$boot_tmp_service_instance"
  echo "Running container with boot..."
  sudo systemd-nspawn --directory "$sysroot" $args
else
  echo "Running container without boot..."
  eval "sudo systemd-nspawn --directory \"$sysroot\" $args $shell_script_command"
fi

if [ ! -z "$boot_run_service" ]; then
  sudo systemd-nspawn --directory "$sysroot" \
    systemctl disable "$boot_tmp_service_instance"

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
