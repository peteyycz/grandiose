# Grandiose: Bordered Terminal UI

## Goal
Render the PTY shell inside a bordered frame. This requires parsing PTY output, maintaining a virtual screen buffer, and rendering with offset coordinates.

## Why This Is Complex
The shell sends raw ANSI escape sequences (cursor movements, colors, clears). If we just pass them through with a border drawn, the shell will overwrite the border because it doesn't know about the offset.

**Solution:** Intercept all PTY output, parse escape sequences, maintain our own screen buffer, then render that buffer inside the border.

## Architecture

```
PTY Output → ANSI Parser → Screen Buffer → Renderer → Real Terminal
                              ↓
                     (width-2 x height-2)
                              ↓
                     Rendered with border
```

## Components

### 1. Screen Buffer (`src/screen.zig`)
A 2D grid of cells representing what the shell "thinks" the screen looks like.

```zig
const Cell = struct {
    char: u21 = ' ',      // Unicode codepoint
    fg: u8 = 7,           // Foreground color (0-255)
    bg: u8 = 0,           // Background color
    bold: bool = false,
    // ... other attributes
};

const Screen = struct {
    cells: [][]Cell,
    width: u16,
    height: u16,
    cursor_row: u16,
    cursor_col: u16,
    // ... saved cursor, scroll region, etc.
};
```

**Operations:**
- `putChar(char)` - write char at cursor, advance cursor
- `moveCursor(row, col)` - absolute positioning
- `moveCursorRel(dr, dc)` - relative movement
- `eraseLine(mode)` - clear line (0=to end, 1=to start, 2=whole)
- `eraseDisplay(mode)` - clear screen
- `scroll(n)` - scroll content up/down

### 2. ANSI Parser (`src/parser.zig`)
State machine that processes bytes and emits commands.

**States:**
- `ground` - normal text, print characters
- `escape` - saw ESC (0x1B)
- `csi` - saw ESC[ (Control Sequence Introducer)
- `osc` - saw ESC] (Operating System Command)

**Key sequences to handle:**
| Sequence | Meaning |
|----------|---------|
| `ESC[H` | Move cursor to (1,1) |
| `ESC[row;colH` | Move cursor to (row,col) |
| `ESC[nA/B/C/D` | Cursor up/down/forward/back n |
| `ESC[J` / `ESC[2J` | Erase display |
| `ESC[K` | Erase to end of line |
| `ESC[m` / `ESC[n;m;...m` | SGR - colors/attributes |
| `ESC[?25h/l` | Show/hide cursor |
| `\r` | Carriage return |
| `\n` | Line feed |
| `\b` | Backspace |

### 3. Renderer (`src/render.zig`)
Draws the screen buffer to the real terminal with border.

**Approach:**
1. On each render, move cursor to (1,1) of real terminal
2. Draw top border: `┌──...──┐`
3. For each row in buffer:
   - Draw `│`
   - Draw row contents with colors
   - Draw `│`
4. Draw bottom border: `└──...──┘`
5. Position real cursor at (buffer.cursor_row + 1, buffer.cursor_col + 1)

**Optimization:** Track dirty regions, only redraw changed cells.

### 4. Main Loop Changes (`src/main.zig`)
```
1. Get terminal size
2. Create Screen buffer (width-2, height-2)
3. Set PTY size to inner dimensions
4. Fork & exec shell (unchanged)
5. Parent loop:
   - Poll stdin and master
   - stdin input → write to master (unchanged)
   - master output → feed to Parser → updates Screen
   - After processing: call Renderer
```

## File Structure
```
src/
  main.zig     # Entry, PTY setup, main loop
  screen.zig   # Screen buffer and cell operations
  parser.zig   # ANSI escape sequence parser
  render.zig   # Border drawing and screen rendering
```

## Implementation Order

### Step 1: Screen Buffer
- Define Cell and Screen structs
- Implement basic operations: putChar, moveCursor, clear
- Test with hardcoded content

### Step 2: Basic Renderer
- Get terminal size (TIOCGWINSZ)
- Draw border using box-drawing chars
- Render buffer contents inside border
- Handle cursor positioning

### Step 3: ANSI Parser (minimal)
- State machine skeleton
- Handle printable characters
- Handle `\r`, `\n`, `\b`
- Handle `ESC[H` (cursor home)
- Handle `ESC[2J` (clear screen)

### Step 4: Integration
- Wire parser output to screen buffer
- Wire screen buffer to renderer
- Test with simple commands (ls, echo)

### Step 5: Extended Parser
- Cursor movement (A/B/C/D)
- Erase line/display variants
- Colors (SGR sequences)
- Iterate based on what breaks

## Verification
1. `zig build && ./zig-out/bin/grandiose`
2. Should see bordered window with shell inside
3. `ls --color` - colors render correctly inside border
4. `clear` - clears inside border, not the whole screen
5. `vim` or `htop` - cursor movement works within border
6. Resize terminal - border redraws (stretch goal)

## Known Limitations (OK for v1)
- No mouse support
- No alternate screen buffer ($TERM apps like vim may glitch)
- No 24-bit color (just 256-color)
- No window resize handling initially
