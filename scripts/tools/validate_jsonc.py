#!/usr/bin/env python3
import json
import sys

def remove_comments(source):
    result = []
    i = 0
    in_string = False
    escaped = False
    in_line_comment = False
    in_block_comment = False

    while i < len(source):
        char = source[i]
        nxt = source[i + 1] if i + 1 < len(source) else ""

        if in_line_comment:
            if char == "\n":
                in_line_comment = False
                result.append("\n")
            else:
                result.append(" ")
            i += 1
            continue

        if in_block_comment:
            if char == "*" and nxt == "/":
                result.extend("  ")
                in_block_comment = False
                i += 2
            else:
                result.append("\n" if char == "\n" else " ")
                i += 1
            continue

        if in_string:
            result.append(char)
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            i += 1
            continue

        if char == '"':
            in_string = True
            result.append(char)
            i += 1
        elif char == "/" and nxt == "/":
            in_line_comment = True
            result.extend("  ")
            i += 2
        elif char == "/" and nxt == "*":
            in_block_comment = True
            result.extend("  ")
            i += 2
        else:
            result.append(char)
            i += 1

    if in_block_comment:
        raise ValueError("Comentario de bloque sin cerrar")

    return "".join(result)


def main():
    if len(sys.argv) != 2:
        print("Uso: validate_jsonc.py archivo", file=sys.stderr)
        return 2

    try:
        with open(sys.argv[1], encoding="utf-8") as file:
            source = file.read()

        json.loads(remove_comments(source))
        print("JSONC válido: " + sys.argv[1])
        return 0

    except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as error:
        print("JSONC no válido: {}".format(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
