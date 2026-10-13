"""Export versioned desktop entries without bypassing the runtime adapter."""

import pathlib
import re
import shlex
import sys


def command_tokens(value):
    # Keep source spans so rewriting the executable never requotes arguments.
    tokens = list(re.finditer(
        r'''(?:[^\s"'\\]|\\.|"(?:[^"\\]|\\.)*"|'[^']*')+''', value
    ))
    end = 0
    words = []
    for token in tokens:
        if value[end:token.start()].strip():
            raise ValueError("invalid desktop command quoting")
        decoded = shlex.split(token.group())
        if len(decoded) != 1:
            raise ValueError("invalid desktop command token")
        words.append(decoded[0])
        end = token.end()
    if value[end:].strip() or not tokens:
        raise ValueError("invalid or empty desktop command")
    return tokens, words


def executable_index(words):
    if pathlib.Path(words[0]).name != "env":
        return 0
    index = 1
    # Only these env options are supported; env -S would introduce a second
    # command parser, and shell commands are deliberately not interpreted.
    variable = r"[A-Za-z_][A-Za-z_0-9]*"
    while index < len(words):
        word = words[index]
        if word == "--":
            index += 1
            break
        if word in ("-i", "--ignore-environment"):
            index += 1
        elif word == "-u":
            if index + 1 == len(words) or not re.fullmatch(variable, words[index + 1]):
                raise ValueError("invalid env -u variable")
            index += 2
        elif word.startswith("--unset=") and re.fullmatch(variable, word[8:]):
            index += 1
        elif word.startswith("-"):
            raise ValueError(f"unsupported env option: {word}")
        else:
            break
    while index < len(words) and re.match(variable + "=", words[index]):
        index += 1
    if index == len(words):
        raise ValueError("missing executable")
    return index


def export_desktops(source, tree, output, template, name, attr, version, command):
    source, tree, output = map(pathlib.Path, (source, tree, output))
    entries = source / "share/applications"
    desktop_files = sorted(entries.glob("*.desktop"))
    if not desktop_files:
        return

    # Match the launcher's glob order: visible binaries before dotfiles.
    binaries = sorted(
        (
            p.name for p in (tree / "bin").iterdir()
            if p.is_file() and p.stat().st_mode & 0o111
        ),
        key=lambda b: (b.startswith("."), b),
    )
    visible = [b for b in binaries if not b.startswith(".")]
    primary = command or next((b for b in visible if b == attr), None)
    primary = primary or next((b for b in visible if b.startswith(attr)), None)
    # The shell's .[!.]* fallback does not include names starting with '..'.
    primary = primary or next((b for b in binaries if not b.startswith("..")), None)
    wrappers = {primary: name}
    launcher = pathlib.Path(template).read_text()
    marker = 'exe="$binDir"/__RETRO_DESKTOP_COMMAND__'
    if launcher.count(marker) != 1:
        raise ValueError("incompatible desktop launcher template: expected one command assignment")
    destination = output / "share/applications"

    def wrapper_path(value):
        executable = pathlib.Path(value)
        # Check lexical ownership, not resolved symlink targets: Nix bin/
        # commonly contains symlinks into another store output.
        if executable.is_absolute():
            if executable.parent not in (source / "bin", tree / "bin"):
                raise ValueError(f"external executable: {value}")
        elif value != executable.name:
            raise ValueError(f"unsupported executable path: {value}")
        executable = executable.name
        if executable not in binaries:
            raise ValueError(f"unsupported executable: {value}")
        if executable not in wrappers:
            # A separate adapter preserves helper executables and desktop actions.
            wrapper = f"{name}-{executable}"
            if wrapper in wrappers.values():
                raise ValueError(f"wrapper name collision: {wrapper}")
            wrappers[executable] = wrapper
            path = output / "bin" / wrapper
            path.write_text(launcher.replace(marker, 'exe="$binDir"/' + shlex.quote(executable)))
            path.chmod(0o755)
        return str(output / "bin" / wrappers[executable])

    def rewrite_exec(value):
        tokens, words = command_tokens(value)
        index = executable_index(words)
        if pathlib.Path(words[index]).name in ("sh", "bash", "dash", "zsh", "ksh", "fish", "csh", "tcsh"):
            raise ValueError("shell commands are not supported")
        path = wrapper_path(words[index])
        path = re.sub(r'([\\"`$])', r'\\\1', path)
        token = tokens[index]
        return value[:token.start()] + '"' + path + '"' + value[token.end():]

    def rewrite_group(group):
        lines = []
        for line in group:
            key, sep, value = line.partition("=")
            if sep and key == "Exec":
                line = key + "=" + rewrite_exec(value)
            elif sep and key == "TryExec":
                # TryExec is a single path, not a quoted command line.
                line = key + "=" + wrapper_path(value)
            elif sep and (key == "Name" or key.startswith("Name[")):
                line += f" ({version})"
            elif sep and key == "Icon" and value and not pathlib.Path(value).is_absolute():
                # Absolute icon paths avoid collisions without exporting the
                # entire upstream share tree into the user's profile.
                icons = []
                for directory in (tree / "share/icons", tree / "share/pixmaps"):
                    if directory.is_dir():
                        icons.extend(
                            p for p in directory.rglob("*")
                            if p.is_file() and (p.name == value or p.stem == value)
                        )
                if icons:
                    line = "Icon=" + str(sorted(icons)[0])
            elif sep and key == "DBusActivatable":
                # Activation under the upstream ID would bypass this wrapper.
                line = "DBusActivatable=false"
            if key not in ("Exec", "TryExec"):
                line = line.replace(str(source) + "/", str(tree) + "/")
            lines.append(line)
        return lines

    for entry in desktop_files:
        groups = []
        for line in entry.read_text().splitlines():
            if (line.startswith("[") and line.endswith("]")) or not groups:
                groups.append([])
            groups[-1].append(line)
        main = next((group for group in groups if group[0] == "[Desktop Entry]"), [])
        # D-Bus-only entries cannot launch under the original activation ID.
        if not any(line.startswith("Exec=") for line in main):
            print(f"retro: skipping {entry.name}: missing main Exec", file=sys.stderr)
            continue
        lines = []
        supported_actions = set()
        try:
            for group in groups:
                action = re.fullmatch(r"\[Desktop Action (.+)\]", group[0])
                if action:
                    try:
                        if not any(line.startswith("Exec=") for line in group):
                            raise ValueError("missing action Exec")
                        rewritten = rewrite_group(group)
                    except ValueError as error:
                        print(f"retro: removing {entry.name} action {action[1]}: {error}", file=sys.stderr)
                        continue
                    supported_actions.add(action[1])
                else:
                    rewritten = rewrite_group(group)
                lines.extend(rewritten)
        except ValueError as error:
            # Do not advertise an entry whose launch command cannot be adapted.
            print(f"retro: skipping {entry.name}: {error}", file=sys.stderr)
            continue
        for index, line in enumerate(lines):
            if line.startswith("Actions="):
                actions = [a for a in line[8:].split(";") if a in supported_actions]
                lines[index] = "Actions=" + "".join(a + ";" for a in actions)
        destination.mkdir(parents=True, exist_ok=True)
        (destination / f"{name}-{entry.name}").write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    export_desktops(*sys.argv[1:])
