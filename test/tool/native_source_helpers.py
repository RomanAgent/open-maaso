"""Read a complete native declaration for focused executable boundary tests."""


def swift_function(source, marker):
    start = source.index(marker)
    cursor = source.index("{", start)
    depth = 0
    while cursor < len(source):
        if source.startswith("//", cursor):
            cursor = source.index("\n", cursor)
            continue
        if source.startswith("/*", cursor):
            cursor = source.index("*/", cursor) + 2
            continue
        if source[cursor] == '"':
            cursor += 1
            while cursor < len(source):
                if source[cursor] == "\\":
                    cursor += 2
                elif source[cursor] == '"':
                    cursor += 1
                    break
                else:
                    cursor += 1
            continue
        if source[cursor] == "{":
            depth += 1
        elif source[cursor] == "}":
            depth -= 1
            if depth == 0:
                return source[start:cursor + 1]
        cursor += 1
    raise ValueError(f"Unterminated native declaration: {marker}")
