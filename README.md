# PiNspawn GitHub Action

GitHub action to use `systemd-nspawn` to run commands in a (un)booted container on a Raspberry Pi SD card image

[`systemd-nspawn`](https://www.freedesktop.org/software/systemd/man/latest/systemd-nspawn.html) is
used to run commands in a light-weight namespace container, like chroot but with full virtualization
of the file system hierarchy, the process tree, the various IPC subsystems, and the host and domain
name. It can also be used to boot the image's init program (which is usually systemd) as an OS; this
action makes it easy to run a set of shell commands whether or not the OS is booted in the
container.

Note that currently only unbooted containers work correctly on GitHub's new hosted arm64 runners;
booted containers spontaneously initiate shutdown as soon as the system boot sequence reaches the
login prompt. Maybe that's a bug which will magically go away after the hosted arm64 runners exit
public preview (this is wishful thinking). For now, if you want to start or interact with the Docker
daemon inside a container on an arm64 runner, you will need instantiate the container with the
`CAP_NET_ADMIN` capability (to make iptables work) and then manually start both containerd (by
launching `/usr/bin/containerd`) and the Docker daemon (by launching `/usr/bin/dockerd`). See the
example listed below for an illustration of this.

## Basic Usage Examples

### Run shell commands as root

```yaml
- name: Install and run cowsay
  uses: ethanjli/pinspawn-action@v0.1.4
  with:
    image: rpi-os-image.img
    run: |
      apt-get update
      apt-get install -y cowsay
      /usr/games/cowsay 'I am running in a light-weight namespace container!'
```

### Run shell commands in a specific shell

```yaml
- name: Run in Python
  uses: ethanjli/pinspawn-action@v0.1.4
  with:
    image: rpi-os-image.img
    shell: python
    run: |
      import platform

      for word in reversed(['!', platform.python_version(), 'Python', 'in', 'running', 'am', 'I']):
        print(word, end=' ')
```

### Run shell commands as the `pi` user

```yaml
- name: Run without root permissions
  uses: ethanjli/pinspawn-action@v0.1.4
  with:
    image: rpi-os-image.img
    user: pi
    shell: sh
    run: |
      sudo apt-get update
      sudo apt-get install -y figlet
      figlet -f digital "I am $USER in $SHELL!"
```

### Run an external script directly, with the shell selected by its shebang line

```yaml
- name: Make a script on the host
  uses: 1arp/create-a-file-action@0.4.5
  with:
    file: figlet.sh
    content: |
      #!/usr/bin/env -S bash -eux
      figlet -f digital "I am $USER in $SHELL!"

- name: Make the script executable
  run: chmod a+x figlet.sh

- name: Run script directly
  uses: ethanjli/pinspawn-action@v0.1.4
  with:
    image: rpi-os-image.img
    args: --bind "$(pwd)":/run/external
    user: pi
    shell: /run/external/figlet.sh
```

### Run shell commands with one or more bind mounts from the host OS

```yaml
- name: Make a bootloader configuration snippet
  uses: 1arp/create-a-file-action@0.4.5
  with:
    file: boot-config.snippet
    content: |
      # Enable support for the RV3028 RTC
      dtoverlay=i2c-rtc,rv3028,trickle-resistor-ohms=3000,backup-switchover-mode=1

- name: Modify bootloader configuration
  uses: ethanjli/pinspawn-action@v0.1.4
  with:
    image: rpi-os-image.img
    args: --bind "$(pwd)":/run/external
    run: |
      cat /run/external/boot-config.snippet >> /boot/config.txt
      cp /boot/config.txt /run/external/boot.config

- name: Print the bootloader config
  run: cat boot.config
```

### Run shell commands in a booted container

Note: the system in the container will shut down after the specified commands finish running.

```yaml
- name: Analyze systemd boot process
  uses: ethanjli/pinspawn-action@v0.1.4
  with:
    image: rpi-os-image.img
    args: --bind "$(pwd)":/run/external
    boot: true
    run: |
      while ! systemd-analyze 2>/dev/null; do
        echo "Waiting for boot to finish..."
        sleep 5
      done
      systemd-analyze critical-chain | cat
      systemd-analyze blame | cat
      systemd-analyze plot > /run/external/bootup-timeline.svg
      echo "Done!"

- name: Upload the bootup timeline to Job Artifacts
  uses: actions/upload-artifact@v4
  with:
    name: bootup-timeline
    path: bootup-timeline.svg
    if-no-files-found: error
    overwrite: true
```

### Interact with Docker in an unbooted container

Note: this example will *only* work if you run it in the `ubuntu-22.04-arm` runner; trying to run it
on `ubuntu-24.04-arm` results in an error when `dockerd` tries to start
(`failed to start daemon: Devices cgroup isn't mounted`).

```yaml
- name: Install Docker
  uses: ethanjli/pinspawn-action@v0.1.4
  with:
    image: rpi-os-image.img
    run: |
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y ca-certificates curl
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
      chmod a+r /etc/apt/keyrings/docker.asc
      echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
        https://download.docker.com/linux/debian \
        $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list
      apt-get update
      apt-get install -y \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

- name: Pull a Docker container image
  uses: ethanjli/pinspawn-action@v0.1.4
  with:
    image: rpi-os-image.img
    args: --capability=CAP_NET_ADMIN
    run: |
      #!/bin/bash -eux

      /usr/bin/containerd &
      sleep 5
      /usr/bin/dockerd &
      sleep 10

      docker image pull hello-world
      docker image ls
```

## Usage Options

Inputs:

| Input         | Allowed values                   | Required?            | Description                                                  |
|---------------|----------------------------------|----------------------|--------------------------------------------------------------|
| `image`       | file path                        | yes                  | Path of the image to use for the container.                  |
| `args`        | `systemd-nspawn` options/args    | no (default ``)      | Options, args, and/or a command to pass to `systemd-nspawn`. |
| `shell`       | ``, `bash`, `sh`, `python`, etc. | no (default ``)      | The shell to use for running commands.                       |
| `run`         | shell commands                   | no (default ``)      | Commands to run in the shell.                                |
| `user`        | name of user in image            | no (default `root`)  | The user to run commands as.                                 |
| `boot`        | `false`, `true`                  | no (default `false`) | Boot the image's init program (usually systemd) as PID 1.    |
| `run-service` | file path                        | no (default ``)      | systemd service to run `shell` with the `run` commands.      |

- `image` must be the path of an unmounted raw disk image (such as a Raspberry Pi OS SD card image),
  where partition 2 should be mounted as the root filesystem (i.e. `/`) and partition 1 should be
  mounted to `/boot`.

- `args` can be a list of command-line options/arguments for
  [`systemd-nspawn`](https://www.freedesktop.org/software/systemd/man/latest/systemd-nspawn.html).
  You should not set the `--user` or `--boot` flags here; instead, you should set the `user` and
  `boot` action inputs.

- If `run` is not left empty, `shell` will be used to execute commands specified in the `run` input.
  You can use built-in `shell` keywords, or you can define a custom set of shell options. The shell
  command that is run internally executes a temporary file that contains the commands to run, like
  [in GitHub Actions](https://docs.github.com/en/actions/using-workflows/workflow-syntax-for-github-actions#jobsjob_idstepsshell).
  Please refer to the GitHub Actions semantics of the `shell` keyword of job steps for details
  about the behavior of this action's `shell` input.

  If you just want to run a single script, you can leave `run` empty and provide that script as the
  `shell` input. However, you will need to set the appropriate permissions on the script file.

- If `boot` is enabled, this action will use `systemd-nspawn` to automatically search for an init
  program in the image (typically systemd) and invoke it as PID 1, instead of a shell.

  - The provided `run` commands will be triggered by a temporary system service defined with the
    following template (unless you specify a different service file template using the `run-service`
    input):

    ```
    [Unit]
    Description=Run commands in booted OS
    After=getty.target

    [Service]
    Type=exec
    ExecStart=bash -c "\
      su - {user} -c '{command}; echo $? | tee {result}'; \
      echo Shutting down...; \
      shutdown now \
    " &
    StandardOutput=tty

    [Install]
    WantedBy=getty.target
    ```

    This service file template has string interpolation applied to the following strings:

    - `{user}` will be replaced with the value of the action's `user` input.
    - `{command}` will be replaced with a command to run your specified `run` commands using your
      specified `shell`
    - `{result}` will be replaced with the path of a temporary file whose contents will be checked
      after the container finishes running to determine whether the command finished successfully
      (in which case the file should be the string `0`); this file is interpreted as holding a
      return code.

  - If this flag is enabled, then any arguments specified as the command line in `args` are used as
    arguments for the init program, i.e. `systemd-nspawn` will be invoked like
    `systemd-nspawn --boot {args}`.
