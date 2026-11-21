/*
 * Hello World Tree — C adapter.
 *
 * C is the floor. Every other language in this repository either compiles to something like C or runs
 * on something written in it, which makes this file the one every other adapter is ultimately talking
 * about.
 *
 * The adapter is a single-pass lexer good enough to find declarations and includes. It is not a
 * preprocessor and does not try to be: a skeleton that marks what was written beats a parse that
 * fails on an unknown macro.
 */

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_NODES 4096
#define MAX_LABEL 128
#define MAX_LINE  512

typedef enum {
    NODE_FILE = 0,
    NODE_SYMBOL,
    NODE_IMPORT,
    NODE_STRUCT,
    NODE_ENUM,
    NODE_TYPEDEF
} node_kind;

static const char *kind_name(node_kind k)
{
    switch (k) {
    case NODE_FILE:    return "file";
    case NODE_SYMBOL:  return "symbol";
    case NODE_IMPORT:  return "import";
    case NODE_STRUCT:  return "struct";
    case NODE_ENUM:    return "enum";
    case NODE_TYPEDEF: return "typedef";
    default:           return "unknown";
    }
}

typedef struct {
    char      label[MAX_LABEL];
    node_kind kind;
    int       line;
} node_t;

typedef struct {
    node_t nodes[MAX_NODES];
    size_t count;
    /* Overflow is recorded rather than silently truncating, because a graph that quietly drops nodes
     * is worse than one that admits it ran out of room. */
    size_t overflow;
} graph_t;

/* Words that appear before a declaration but are not the declared name. */
static const char *reserved[] = {
    "if", "else", "for", "while", "do", "switch", "case", "return",
    "sizeof", "static", "extern", "inline", "const", "volatile",
    "register", "auto", "goto", "break", "continue", "default",
    NULL
};

static int is_reserved(const char *word)
{
    for (int i = 0; reserved[i] != NULL; i++) {
        if (strcmp(reserved[i], word) == 0) {
            return 1;
        }
    }
    return 0;
}

static void graph_add(graph_t *g, const char *label, node_kind kind, int line)
{
    if (g->count >= MAX_NODES) {
        g->overflow++;
        return;
    }
    node_t *n = &g->nodes[g->count++];
    snprintf(n->label, MAX_LABEL, "%s", label);
    n->kind = kind;
    n->line = line;
}

/* Copy the next identifier-shaped token starting at *p into out, advancing *p past it. */
static int take_word(const char **p, char *out)
{
    const char *s = *p;
    while (*s && isspace((unsigned char)*s)) s++;
    if (!isalpha((unsigned char)*s) && *s != '_') return 0;

    size_t n = 0;
    while ((isalnum((unsigned char)*s) || *s == '_') && n + 1 < MAX_LABEL) {
        out[n++] = *s++;
    }
    out[n] = '\0';
    *p = s;
    return 1;
}

/*
 * Scan one line.
 *
 * Deliberately shallow: find the first meaningful word and decide from it. That misses declarations
 * split across lines, which is fine — the skeleton is for orientation, and an orientation that is 90%
 * right is more useful than a parse that refuses to run.
 */
static void scan_line(graph_t *g, const char *line, int number)
{
    const char *p = line;
    char word[MAX_LABEL];

    while (*p && isspace((unsigned char)*p)) p++;
    if (p[0] == '/' && p[1] == '/') return;
    if (p[0] == '/' && p[1] == '*') return;

    if (p[0] == '#') {
        p++;
        if (!take_word(&p, word)) return;
        if (strcmp(word, "include") == 0) {
            while (*p && (*p == ' ' || *p == '\t')) p++;
            if (*p == '<' || *p == '"') {
                char opener = *p++;
                const char *start = p;
                while (*p && *p != opener) p++;
                size_t len = (size_t)(p - start);
                if (len > 0 && len < MAX_LABEL) {
                    char header[MAX_LABEL];
                    memcpy(header, start, len);
                    header[len] = '\0';
                    graph_add(g, header, NODE_IMPORT, number);
                }
            }
        }
        return;
    }

    if (!take_word(&p, word)) return;
    if (is_reserved(word)) return;

    if (strcmp(word, "struct") == 0 || strcmp(word, "union") == 0) {
        if (take_word(&p, word)) graph_add(g, word, NODE_STRUCT, number);
        return;
    }
    if (strcmp(word, "enum") == 0) {
        if (take_word(&p, word)) graph_add(g, word, NODE_ENUM, number);
        return;
    }
    if (strcmp(word, "typedef") == 0) {
        /* The name is the last word before the semicolon, not the first. */
        const char *semi = strchr(p, ';');
        if (!semi) return;
        const char *q = semi;
        while (q > p && (isspace((unsigned char)q[-1]) || q[-1] == '*')) q--;
        const char *end = q;
        while (q > p && (isalnum((unsigned char)q[-1]) || q[-1] == '_')) q--;
        size_t len = (size_t)(end - q);
        if (len > 0 && len < MAX_LABEL) {
            char name[MAX_LABEL];
            memcpy(name, q, len);
            name[len] = '\0';
            graph_add(g, name, NODE_TYPEDEF, number);
        }
        return;
    }

    /*
     * A function definition or prototype looks like: type name(...)
     * So skip the return type, take the next word, and confirm a paren follows.
     */
    char candidate[MAX_LABEL];
    if (!take_word(&p, candidate)) return;
    if (is_reserved(candidate)) return;

    while (*p && isspace((unsigned char)*p)) p++;
    if (*p == '(') {
        graph_add(g, candidate, NODE_SYMBOL, number);
    }
}

/**
 * Extract a skeleton from a C source file.
 *
 * Returns 0 on success, non-zero if a required argument was null. Overflow is reported through
 * `out->overflow` rather than a return code, because a partial graph is still useful.
 */
int hwt_extract(const char *filename, const char *source, graph_t *out)
{
    if (!filename || !source || !out) return -1;

    memset(out, 0, sizeof(*out));
    graph_add(out, filename, NODE_FILE, 0);

    const char *line = source;
    int number = 1;
    while (*line) {
        const char *eol = strchr(line, '\n');
        size_t len = eol ? (size_t)(eol - line) : strlen(line);

        if (len > 0 && len < MAX_LINE) {
            char buf[MAX_LINE];
            memcpy(buf, line, len);
            buf[len] = '\0';
            scan_line(out, buf, number);
        }

        if (!eol) break;
        line = eol + 1;
        number++;
    }

    return 0;
}

#ifdef HWT_SELFTEST
int main(void)
{
    const char *sample =
        "#include <stdio.h>\n"
        "#include \"local.h\"\n"
        "\n"
        "struct point { int x, y; };\n"
        "typedef unsigned long word_t;\n"
        "\n"
        "static int helper(int a)\n"
        "{\n"
        "    if (a > 0) return a;\n"
        "    return 0;\n"
        "}\n"
        "\n"
        "int main(void)\n"
        "{\n"
        "    return helper(1);\n"
        "}\n";

    graph_t g;
    if (hwt_extract("sample.c", sample, &g) != 0) {
        fprintf(stderr, "extract failed\n");
        return 1;
    }

    for (size_t i = 0; i < g.count; i++) {
        printf("%-10s %-16s line %d\n", kind_name(g.nodes[i].kind), g.nodes[i].label, g.nodes[i].line);
    }

    if (g.overflow) {
        fprintf(stderr, "overflowed by %zu nodes\n", g.overflow);
        return 1;
    }
    return 0;
}
#endif
