-- The interfaces of rendering (lua-language-server annotations; nothing runs here): what a
-- chart renderer, a canvas, ticks, a palette and a frame provide, registered by name in
-- render/registry.lua (ARCHITECTURE.md#interfaces).

---@class dbdash.render.ChartRenderer chart/<type>/<name>
---@field name string? (default: the last part of its registry name)
---@field render fun(rs: dbdash.db.ResultSet, show: table, ctx: dbdash.render.Ctx):
---  dbdash.render.Output

---@class dbdash.render.CanvasType canvas/<name>
---@field name string? (default: the last part of its registry name)
---@field px_per_char { x: integer, y: integer } pixels in one character cell
---@field new fun(cols: integer, rows: integer, xlim: number[], ylim: number[]):
---  dbdash.render.Canvas

---@class dbdash.render.Ticks ticks/<name>
---@field ticks fun(lo: number, hi: number, count: integer): number[], string[]
---@field limits fun(lo: number, hi: number, count: integer): number, number, number

---@class dbdash.render.Palette palette/<name>
---@field color fun(i: integer): string the highlight group of series i

---@class dbdash.render.Frame frame/<name>
---@field render fun(ctx: dbdash.render.Ctx, spec: table, body: table): dbdash.render.Output
---@field plot_size fun(ctx: dbdash.render.Ctx, spec: table): integer, integer
---@field apply_style fun(ctx: dbdash.render.Ctx, spec: table)

---@class dbdash.render.Canvas
---@field cols integer
---@field rows integer
---@field px_x integer
---@field px_y integer
---@field xlim number[]
---@field ylim number[]
---@field glyph fun(mask: integer): string

---@class dbdash.render.Ctx
---@field width integer
---@field height integer
---@field color fun(spec: string?, fallback: string?): string
---@field strwidth fun(s: string): integer
---@field canvas fun(cols: integer, rows: integer, xlim: number[], ylim: number[]):
---  dbdash.render.Canvas a canvas of cols x rows characters over xlim x ylim
---@field canvas_type dbdash.render.CanvasType the canvas's type (px_per_char)
---@field ticks fun(lo: number, hi: number, count: integer): number[], string[]
---@field limits fun(lo: number, hi: number, count: integer): number, number, number
---@field frame dbdash.render.Frame
---@field palette fun(i: integer): string
---@field history number[]? recent values of this panel, oldest first (stat charts)
---@field css dbdash.css.Scope style queries on the chart's element and its parts
---@field plot_height integer? the plot's rows: plot { height } (or the whole cell)
---@field min_plot_height integer? at least plot { min-height }

---@class dbdash.render.Highlight
---@field row integer
---@field col_s integer
---@field col_e integer
---@field group string
---@field priority integer?

---@class dbdash.render.Output
---@field lines string[]
---@field hl dbdash.render.Highlight[] 0-based rows, byte columns
---@field hits { row_s: integer, row_e: integer, x: integer?, width: integer?, node: table }[]?
---  where elements inside are (hit testing)
---@field full boolean? keeps its full width (a background or border)
---@field title_end integer? a box's border: the display column after its title (paint/box)
---@field status_slot dbdash.paint.StatusSlot? a painted panel: where its status goes

local M = {}

return M
