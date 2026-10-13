# Custom logos

Each folder in `Resources/Logos/` is one selectable logo. The folder name is the name shown in the dropdown.

```
Resources/Logos/<name>/
  <anything>.ttf | .otf   font (required, exactly one)
  fill.png | fill.gif     font fill (optional)
  vfx.png | vfx.gif       special effects (optional)
  style.json              properties for the three assets above (optional)
```

Missing or invalid values in `style.json` fall back to the defaults listed below. Unknown keys are ignored.

For properties that enable a special effect, `0` means disabled and any other value enables it and sets it to that value.

## font

| Key | Default | Description |
| --- | --- | --- |
| `size` | `1` | Size multiplier. `0` or omitted means `1`. |
| `emphasisScale` | `0` | Size of the leading "ZS" relative to the rest. `0` keeps the built-in ratio. |
| `spacing` | `0` | Letter spacing in points. Negative tightens. |
| `baselineOffset` | `0` | Vertical nudge in points. Positive moves up. |
| `textCase` | `"none"` | `"none"`, `"upper"` or `"lower"`. |
| `color` | `"#FFFFFF"` | `#RRGGBB` or `#RRGGBBAA`. Used when there is no fill. |
| `shadow` | `0` | Drop shadow blur radius. `0` disables. Use a small value like `0.1` for a hard shadow. |
| `shadowOffset` | `[0, 0]` | `[x, y]` in points. |
| `shadowColor` | `"#000000"` | Shadow color. |
| `shadowOpacity` | `1` | `0` to `1`. |
| `stroke` | `0` | Outline width in points. `0` disables. |
| `strokeColor` | `"#000000"` | Outline color. |

## fill and vfx

| Key | Default | Description |
| --- | --- | --- |
| `enabled` | `true` | Turns the asset off without deleting the file. |
| `speed` | `1` | GIF playback multiplier. `0` freezes on the first frame. Ignored for PNG. |
| `opacity` | `1` | `0` to `1`. |
| `scale` | `1` | Size multiplier. |
| `offset` | `[0, 0]` | `[x, y]` in points. `[0, 0]` disables. |
| `rotation` | `0` | Degrees, positive is clockwise. `0` disables. |
| `blendMode` | `"normal"` | `normal`, `multiply`, `screen`, `overlay`, `softLight`, `hardLight`, `colorDodge`, `colorBurn`, `darken`, `lighten`, `difference`, `exclusion`, `add`. |

`vfx` also supports:

| Key | Default | Description |
| --- | --- | --- |
| `layer` | `"above"` | `"above"` or `"below"` the text. |
| `maskToText` | `false` | Clip the effect to the glyph shapes. |

