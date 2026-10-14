-- osmo-conky.lua - le PANNEAU du tableau de bord Conky du banc (Cairo).
--
-- [2026-10-12] POURQUOI. Le fond d ecran est maintenant une ville sous un
-- ciel bleu clair (configs/gsm-lab-ville.jpg / gsm-lab-antenne.jpg) : du texte
-- pose a meme le ciel, meme avec une ombre, se lisait mal, et les barres
-- cyan se perdaient dans le bleu. Conky ne sait dessiner qu un rectangle
-- plein (own_window_colour + argb) : d ou ce petit Lua, charge par
-- osmo-conky.conf (lua_load / lua_draw_hook_pre), qui peint AVANT le texte :
--   - une plaque sombre translucide, aux coins arrondis, qui laisse voir le
--     ciel au travers ;
--   - un filet clair d un pixel tout autour ;
--   - un trait d accent (le bleu du banc) le long du bord haut.
-- Conky 1.19 (conky-all, Ubuntu 24.04) : les bindings Cairo sont dans
-- « cairo » et, pour la surface X11, « cairo_xlib » (absent des versions
-- anterieures - on le charge sans l exiger).
require 'cairo'
pcall(require, 'cairo_xlib')

-- Les reglages du panneau (fond, filet, accent) : rgba 0..1.
local FOND     = {0.03, 0.06, 0.12, 0.42}
local FILET    = {1.00, 1.00, 1.00, 0.16}
local ACCENT   = {0.35, 0.78, 0.98, 0.95}   -- #5ac8fa, le bleu du banc
local RAYON    = 16
local MARGE    = 1                          -- le filet ne doit pas raser le bord

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

    -- la plaque
    arrondi(cr, MARGE + 0.5, MARGE + 0.5, w - 2 * MARGE - 1, h - 2 * MARGE - 1, RAYON)
    cairo_set_source_rgba(cr, FOND[1], FOND[2], FOND[3], FOND[4])
    cairo_fill_preserve(cr)
    -- le filet
    cairo_set_source_rgba(cr, FILET[1], FILET[2], FILET[3], FILET[4])
    cairo_set_line_width(cr, 1)
    cairo_stroke(cr)

    -- l accent : un trait sous le bord haut, entre les deux arrondis
    cairo_new_path(cr)
    cairo_move_to(cr, MARGE + RAYON, MARGE + 2)
    cairo_line_to(cr, w - MARGE - RAYON, MARGE + 2)
    cairo_set_source_rgba(cr, ACCENT[1], ACCENT[2], ACCENT[3], ACCENT[4])
    cairo_set_line_width(cr, 2)
    cairo_stroke(cr)

    cairo_destroy(cr)
    cairo_surface_destroy(cs)
end
