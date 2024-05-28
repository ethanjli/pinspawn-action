# PiNspawn GitHub Action

GitHub action to use `systemd-nspawn` to run commands in a namespace container attached to a Raspberry Pi SD card image

[`systemd-nspawn`](https://www.freedesktop.org/software/systemd/man/latest/systemd-nspawn.html) is
used to run commands in a light-weight namespace container, like chroot but with full virtualization
of the file system hierarchy, the process tree, the various IPC subsystems, and the host and domain
name. It can also be used to boot the image's init program (which is usually systemd) as an OS; this
action makes it easy to run a set of shell commands whether or not the OS is booted in the
container.

Note that you cannot start or interact with the Docker daemon inside a container booted with
`systemd-nspawn`; instead, you should perform those operations inside a booted QEMU VM attached to
your image, e.g. using the [`ethanjli/piqemu-action`](https://github.com/ethanjli/piqemu-action)
GitHub action.

## Basic Usage Examples

### Run shell commands

```yaml
- name: Install and run cowsay
  uses: ethanjli/pinspawn-action@v0.1.0
  with:
    image: rpi-os-image.img
    run: |
      echo $SHELL
      apt-get update
      apt-get install -y cowsay
      /usr/games/cowsay 'I am running in a light-weight namespace container!'
```

### Run shell commands in a specific shell

```yaml
- name: Run Python
  uses: ethanjli/pinspawn-action@v0.1.0
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
- name: 
  uses: ethanjli/pinspawn-action@v0.1.0
  with:
    image: rpi-os-image.img
    shell: su - pi bash -e {0}
    run: |
      sudo apt-get update
      sudo apt-get install -y figlet
      figlet "I am $USER!"
```

### Run a specific command without a shell

```yaml
- name: Check os-release
  uses: ethanjli/pinspawn-action@v0.1.0
  with:
    image: rpi-os-image.img
    shell: cat /usr/lib/os-release
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
  uses: ethanjli/pinspawn-action@v0.1.0
  with:
    image: rpi-os-image.img
    args: --bind ./:/run/external
    run: |
      cat /run/external/boot-config.snippet >> /boot/config.txt
      cp /boot/config.txt /run/external/boot.config

- name: Print the bootloader config
  run: cat boot.config
```

### Run shell commands in a booted container

Note: the system will shut down after the specified commands finish running.

```yaml
- name: Analyze systemd boot process
  uses: ethanjli/pinspawn-action@v0.1.0
  with:
    image: rpi-os-image.img
    args: |
      --bind ./:/run/external
    boot: true
    run: |
      systemd-analyze blame
      systemd-analyze plot > /run/external/bootup-timeline.svg

- name: Upload the bootup timeline to Job Artifacts
  uses: actions/upload-artifact@v4
  with:
    name: bootup-timeline
    path: bootup-timeline.svg
    if-no-files-found: error
    overwrite: true
```

## Usage Options

Inputs:

| Input         | Allowed values                | Required?            | Description                                                  |
|---------------|-------------------------------|----------------------|--------------------------------------------------------------|
| `image`       | file path                     | yes                  | Path of the image to use for the container.                  |
| `args`        | `systemd-nspawn` options/args | no (default ``)      | Options, args, and/or a command to pass to `systemd-nspawn`. |
| `shell`       | ``, `bash`, `sh`, `python`    | no (default ``)      | The shell to use for running commands.                       |
| `run`         | shell commands                | no (default ``)      | Commands to run in the shell.                                |
| `boot`        | `false`, `true`               | no (default `false`) | Boot the image's init program (usually systemd) as PID 1.    |
| `run-service` | file path                     | no (default ``)      | systemd service to run `shell` with the `run` commands.      |

- `image` must be the path of an unmounted raw disk image (such as a Raspberry Pi OS SD card image),
  where partition 2 should be mounted as the root filesystem (i.e. `/`) and partition 1 should be
  mounted to `/boot`.

- `args` can be a list of command-line options/arguments for
  [`systemd-nspawn`](https://www.freedesktop.org/software/systemd/man/latest/systemd-nspawn.html).

- If `run` is not left empty, `shell` will be used to execute commands specified in the `run` input.
  You can use built-in `shell` keywords, or you can define a custom set of shell options. The shell
  command that is run internally executes a temporary file that contains the commands to run, like
  [in GitHub Actions](https://docs.github.com/en/actions/using-workflows/workflow-syntax-for-github-actions#jobsjob_idstepsshell).
  Please refer to the GitHub Actions semantics of the `shell` keyword of job steps for details
  about the behavior of this action's `shell` input.

  If you want to run a single custom command without a shell, you should leave `run` empty and
  provide a custom command as the `shell` input.

- If `boot` is enabled, this action will use `systemd-nspawn` to automatically search for an init
  program in the image (typically systemd) and invoke it as PID 1, instead of a shell.

  - The provided `run` commands will be triggered by a temporary system service defined with the
    following template (unless you specify a different service using the `run-service` input):

    ```
    [Unit]
    Description=Perform booted OS setup
    After=getty.target

    [Service]
    type=oneshot
    Environment=DEBIAN_FRONTEND=noninteractive
    ExecStartPre=echo "Running OS setup..."
    ExecStart=bash -c '{0}; echo "$?" > %I; shutdown now'
    StandardOutput=tty

    [Install]
    WantedBy=getty.target
    ```

    Note that `{0}` in the template will be replaced with a command to run your specified `run`
    commands using your specified `shell`, while `%I` will be replaced with the path of a file
    whose contents will be checked after the container finishes running to determine whether the
    command finished successfully (in which case the file should be the string `0`).

  - After any provided `run` commands finish executing, the container will shut down.
  - If this flag is enabled, then any arguments specified as the command line in `args` are used as
    arguments for the init program, i.e. `systemd-nspawn` will be invoked like
    `systemd-nspawn --boot {args}`.