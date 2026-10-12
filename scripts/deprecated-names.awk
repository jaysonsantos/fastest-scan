# Print the full path of each deprecated declaration at the top level of the files
# of the Zig standard library, for example "std.mem.indexOf". The input files have
# paths relative to the directory of the library: "./mem.zig", "./Io/Dir.zig".
# scripts/check-deprecated.sh runs this program.
#
# A doc comment with a line that starts with "Deprecated" marks the declaration
# after it.

FNR == 1 { marked = 0 }

/^\/\/\/ *[Dd]eprecated/ { marked = 1; next }

# The other lines of the doc comment.
/^\/\/\// { next }

marked && /^pub (inline )?(const|fn|var) / {
    name = $0
    sub(/^pub (inline )?(const|fn|var) /, "", name)
    sub(/[^A-Za-z0-9_].*$/, "", name)
    path = FILENAME
    sub(/^\.\//, "", path)
    sub(/\.zig$/, "", path)
    gsub(/\//, ".", path)
    # std.zig is the root of the library: its names are `std.NAME`.
    if (path == "std") print "std." name
    else print "std." path "." name
}

{ marked = 0 }
