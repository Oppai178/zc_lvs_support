from pathlib import Path
from luaparser import ast
import re, sys

path = Path(r'C:\Users\lazyg\Desktop\zc_mod\zc_lvs_support\lua\zc_lvs_support\sv_seats.lua')
src = path.read_text(encoding='utf-8', errors='replace')
src = re.sub(r'(?<![.\w])continue(?=\s)', 'do end', src)
lines = src.split('\n')

# Instrument: wrap ast.parse with a custom error listener capturing the
# offending token. luaparser hides it; use antlr directly on its lexer.
from luaparser.parser.LuaLexer import LuaLexer
from antlr4 import InputStream, CommonTokenStream

inp = InputStream(src)
lexer = LuaLexer(inp)
tokens = CommonTokenStream(lexer)
tokens.fill()

# Report first offending token via parser with a listener that does not raise.
from luaparser.parser.LuaParser import LuaParser
from antlr4.error.ErrorListener import ErrorListener

class Collector(ErrorListener):
    def __init__(self):
        self.errors = []
    def syntaxError(self, recognizer, offendingSymbol, line, column, msg, e):
        tok = offendingSymbol
        text = tok.text if tok is not None else '?'
        # find surrounding source line
        l = lines[line-1] if 0 < line <= len(lines) else ''
        self.errors.append((line, column, msg[:120], text, l.strip()[:90]))

c = Collector()
parser = LuaParser(tokens)
parser.removeErrorListeners()
parser.addErrorListener(c)
try:
    parser.start_()
except Exception as e:
    pass

for e in c.errors[:12]:
    print('line %d col %d: %s | token=%r' % (e[0], e[1], e[2], e[3]))
    print('   src:', e[4])
print('total errors:', len(c.errors))
