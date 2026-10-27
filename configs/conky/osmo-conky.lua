-- osmo-conky.lua - Cairo panel of the bench's Conky dashboard.
--
-- Loaded by osmo-conky.conf (lua_load / lua_draw_hook_pre = 'panneau'). Conky
-- can only draw a solid rectangle (own_window_colour + argb), so this hook
-- paints, before the text:
--   - a translucent dark panel with rounded corners (the wallpaper,
--     configs/gsm-lab-ville.jpg, shows through);
--   - a one-pixel light outline all around;
--   - an accent line (the bench blue) along the top edge.
-- Conky 1.19 (conky-all, Ubuntu 24.04): the Cairo bindings are in "cairo"
-- and, for the X11 surface, "cairo_xlib" (absent from older versions, so it
-- is loaded without being required).
require 'cairo'
pcall(require, 'cairo_xlib')

-- Panel settings (background, outline, accent): rgba 0..1.
local FOND     = {0.03, 0.06, 0.12, 0.42}
local FILET    = {1.00, 1.00, 1.00, 0.16}
local ACCENT   = {0.35, 0.78, 0.98, 0.95}   -- #5ac8fa, the bench blue
local RAYON    = 16
local MARGE    = 1                          -- the outline must not touch the edge

local function arrondi(cr, x, y, w, h, r)
    cairo_new_path(cr)
    cairo_arc(cr, x + w - r, y + r, r, -math.pi / 2, 0)
    cairo_arc(cr, x + w - r, y + h - r, r, 0, math.pi / 2)
    cairo_arc(cr, x + r, y + h - r, r, math.pi / 2, math.pi)
    cairo_arc(cr, x + r, y + r, r, math.pi, 3 * math.pi / 2)
    cairo_close_path(cr)
end

function conky_panneau()
    if conky_window == nil then return end
    local w, h = conky_window.width, conky_window.height
    if w < 2 or h < 2 then return end
    local cs = cairo_xlib_surface_create(conky_window.display, conky_window.drawable,
                                         conky_window.visual, w, h)
    local cr = cairo_create(cs)

    -- the panel
    arrondi(cr, MARGE + 0.5, MARGE + 0.5, w - 2 * MARGE - 1, h - 2 * MARGE - 1, RAYON)
    cairo_set_source_rgba(cr, FOND[1], FOND[2], FOND[3], FOND[4])
    cairo_fill_preserve(cr)
    -- the outline
    cairo_set_source_rgba(cr, FILET[1], FILET[2], FILET[3], FILET[4])
    cairo_set_line_width(cr, 1)
    cairo_stroke(cr)

    -- the accent: a line under the top edge, between the two rounded corners
    cairo_new_path(cr)
    cairo_move_to(cr, MARGE + RAYON, MARGE + 2)
    cairo_line_to(cr, w - MARGE - RAYON, MARGE + 2)
    cairo_set_source_rgba(cr, ACCENT[1], ACCENT[2], ACCENT[3], ACCENT[4])
    cairo_set_line_width(cr, 2)
    cairo_stroke(cr)

    cairo_destroy(cr)
    cairo_surface_destroy(cs)
end
