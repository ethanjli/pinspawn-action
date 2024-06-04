#!/bin/bash -eu

mount_image() {
  local image
  image="$1"
  local sysroot
  sysroot="${2:-}"

  device="$(sudo losetup -fP --show "$image")"
  if [ -z "$device" ]; then
    echo "Error: couldn't mount $image!"
    return 1
  fi

  if [ -z "$sysroot" ]; then
    echo "$device"
    return 0
  fi

  sudo mkdir -p "$sysroot"
  sudo mount "${device}p2" "$sysroot" 1>&2
  sudo mount "${device}p1" "$sysroot/boot" 1>&2

  echo $device
}

unmount_image() {
  local device
  device="$1"
  local sysroot
  sysroot="${2:-}"

  if [ ! -z "$sysroot" ]; then
    sudo umount "$sysroot/boot"
    sudo umount "$sysroot"
  fi

  sudo e2fsck -p -f "${device}p2" | grep -v 'could be narrower.  IGNORED.'
  sudo losetup -d "$device"
}

interpolate_boot_run_service_line() {
  local line
  line="$1"
  local user
  user="$2"
  local shell_script_command
  shell_script_command="$3"
  local result_file
  result_file="$4"

  local interpolated
  interpolated="$line"
  local interpolated_next
  # Interpolate {user}:
  interpolated_next="$(\
    printf '%s' "$interpolated" | awk -v r="$user" -e 'gsub(/{user}/, r)' \
  )"
  if [ -z "$interpolated_next" ]; then # line didn't have {user}
    interpolated_next="$interpolated"
  fi
  interpolated="$interpolated_next"

  # Interpolate {command}:
  interpolated_next="$(\
    printf '%s' "$interpolated" | awk -v r="$shell_script_command" -e 'gsub(/{command}/, r)' \
  )"
  if [ -z "$interpolated_next" ]; then # line didn't have {command}
    interpolated_next="$interpolated"
  fi
  interpolated="$interpolated_next"

  # Interpolate {result}:
  interpolated_next="$(\
    printf '%s' "$interpolated" | awk -v r="$result_file" -e 'gsub(/{result}/, r)' \
  )"
  if [ -z "$interpolated_next" ]; then # line didn't have {result}
    interpolated_next="$interpolated"
  fi
  interpolated="$interpolated_next"

  echo "$interpolated"
}

image="$1" # e.g. "rpi-os-image.img"
user="$2" # e.g. "pi"
boot_run_service="$3" # e.g. "/path/to/default-boot-run.service"
args="$4" # e.g. "--bind /path/in/host:/path/in/container"
shell_command="$5" # e.g. "bash -e {0}"

# Mount the image
sysroot="$(sudo mktemp -d --tmpdir=/mnt sysroot.XXXXXXX)"
device="$(mount_image "$image" "$sysroot")"

# Make a shell script with the run commands
# Note: we can't use `/tmp` because it will be remounted by the container
tmp_script="$(sudo mktemp --tmpdir="$sysroot/usr/bin" pinspawn-script.XXXXXXX)"
# Note: this command reads & processes stdin:
sudo tee "$tmp_script" > /dev/null
sudo chmod a+x "$tmp_script"
container_tmp_script="${tmp_script#"$sysroot"}"
sudo systemd-nspawn --directory "$sysroot" --quiet \
  chown "$user" "$container_tmp_script"

# Prepare the shell script command
shell_script_command="$(\
  printf '%s' "$shell_command" | awk -v r="$container_tmp_script" -e 'gsub(/{0}/, r)' \
)"
if [ -z "$shell_script_command" ]; then
  # shell_command didn't have {0}, so we'll just use it verbatim:
  shell_script_command="$shell_command"
fi

if [ ! -z "$boot_run_service" ]; then
  echo "Preparing to run commands during container boot..."
  args="--boot $args"

  # Inject the shell script into the container
  boot_tmp_script="$(sudo mktemp --tmpdir="$sysroot/usr/bin" pinspawn-script.XXXXXXX)"
  sudo cp "$tmp_script" "$boot_tmp_script"
  sudo chmod a+x "$boot_tmp_script"
  sudo systemd-nspawn --directory "$sysroot" --quiet \
    chown "$user" "${boot_tmp_script#"$sysroot"}"

  # Inject into the container a service to run the shell script command and record its return value
  boot_tmp_result="$(sudo mktemp --tmpdir="$sysroot/var/lib" pinspawn-status.XXXXXXX)"
  sudo systemd-nspawn --directory "$sysroot" --quiet \
    chown "$user" "${boot_tmp_result#"$sysroot"}"
  boot_tmp_service="$(\
    sudo mktemp --tmpdir="$sysroot/etc/systemd/system" --suffix=".service" pinspawn.XXXXXXX \
  )"
  readarray -t lines < "$boot_run_service"
  for line in "${lines[@]}"; do
    printf '%s\n' "$(\
      interpolate_boot_run_service_line \
        "$line" "$user" "$shell_script_command" "${boot_tmp_result#"$sysroot"}" \
    )" | \
      sudo tee --append "$boot_tmp_service" > /dev/null
  done
  sudo chmod a+r "$boot_tmp_service"
  echo "Boot run service $boot_tmp_service:"
  cat "$boot_tmp_service"
  container_boot_tmp_service="${boot_tmp_service#"$sysroot/etc/systemd/system/"}"
  sudo systemd-nspawn --directory "$sysroot" --quiet \
    systemctl enable "$container_boot_tmp_service"

  # Ensure that default.target is not graphical.target
  tmp_default_target="$(sudo mktemp --tmpdir="$sysroot/var/lib" piqemu-default-target.XXXXXXX)"
  sudo systemd-nspawn --directory "$sysroot" --quiet \
    bash -c "systemctl get-default | sudo tee \"${tmp_default_target#"$sysroot"}\" > /dev/null"
  default_target="$(sudo cat "$tmp_default_target")"
  sudo rm "$tmp_default_target"
  if [ "$default_target" == "graphical.target" ]; then
    sudo systemd-nspawn --directory "$sysroot" --quiet \
      systemctl set-default multi-user.target
  fi

  # Mask userconfig.service
  tmp_userconfig_enabled="$(sudo mktemp --tmpdir="$sysroot/var/lib" piqemu-userconfig-enabled.XXXXXXX)"
  sudo systemd-nspawn --directory "$sysroot" --quiet \
    bash -c "systemctl is-enabled userconfig.service | sudo tee \"${tmp_userconfig_enabled#"$sysroot"}\" > /dev/null || true"
  userconfig_enabled="$(sudo cat "$tmp_userconfig_enabled")"
  sudo rm "$tmp_userconfig_enabled"
  if [[ "$userconfig_enabled" != "not-found" && "$userconfig_enabled" != masked* ]]; then
    sudo systemd-nspawn --directory "$sysroot" --quiet \
      systemctl mask userconfig.service
  fi

# Mask userconfig.service
tmp_userconfig_enabled="$(sudo mktemp --tmpdir="$sysroot/var/lib" piqemu-userconfig-enabled.XXXXXXX)"
sudo systemd-nspawn --directory "$sysroot" --quiet \
  bash -c "systemctl is-enabled userconfig.service | sudo tee \"${tmp_userconfig_enabled#"$sysroot"}\" > /dev/null || true"
userconfig_enabled="$(sudo cat "$tmp_userconfig_enabled")"
sudo rm "$tmp_userconfig_enabled"
if [[ "$userconfig_enabled" != "not-found" && "$userconfig_enabled" != masked* ]]; then
  sudo systemd-nspawn --directory "$sysroot" --quiet \
    systemctl mask userconfig.service
fi

  echo "Running container with boot..."
  # We use eval to work around word splitting in strings inside quotes in args:
  eval "sudo systemd-nspawn --directory \"$sysroot\" $args"
else
  # We can't boot if a non-root user is set, so we only set this flag for unbooted containers:
  if [ ! -z "$user" ]; then
    args="--user $user $args"
  fi
  echo "Running container without boot..."
  # We use eval to work around word splitting in strings inside quotes in shell_script_command:
  eval "sudo systemd-nspawn --directory \"$sysroot\" $args $shell_script_command"
fi

if [ ! -z "$boot_run_service" ]; then
  # Restore the initial state of userconfig.service
  if [[ "$userconfig_enabled" != "not-found" && "$userconfig_enabled" != masked* ]]; then
    sudo systemd-nspawn --directory "$sysroot" --quiet \
      systemctl unmask userconfig.service
  fi

  # Restore the initial state of default.target
  sudo systemd-nspawn --directory "$sysroot" --quiet \
    bash -c "systemctl set-default $default_target"

  # Clean up the injected service
  sudo systemd-nspawn --directory "$sysroot" --quiet \
    systemctl disable "$container_boot_tmp_service"
  sudo rm -f "$boot_tmp_service"

  # Check the return code of the shell script
  # Note: this is not needed in unbooted containers because errors there are propagated to the
  # caller of the script
  if ! sudo cat "$boot_tmp_result" > /dev/null; then
    echo "Error: $boot_run_service did not store a result indicating success/failure!"
    exit 1
  elif [ "$(sudo cat "$boot_tmp_result")" != "0" ]; then
    result="$(sudo cat "$boot_tmp_result")"
    echo "Error: $boot_run_service failed while running $shell_script_command: $result"
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

  # Clean up the shell script
  sudo rm -f "$boot_tmp_script"
fi

# Clean up the shell script
sudo rm -f "$tmp_script"

# Clean up the mount
unmount_image "$device" "$sysroot"
