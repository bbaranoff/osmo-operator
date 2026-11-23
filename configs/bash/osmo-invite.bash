# /etc/osmo-invite.bash - the bench prompt (configs/bash/osmo-invite.bash).
#
# Sourced LAST by ~/.bashrc (one line added by iso_modules/86-finitions.sh and
# update.sh), so it wins over the Ubuntu prompt and the older blocks.
#
#   root    user in red, host ORANGE, path blue, then a GREEN telephone,
#           OFF THE HOOK (☏) in place of « # »: root can call, the line is open
#   others  user cyan, host ORANGE, path blue, then a RED telephone, HUNG UP
#           (☎) in place of « $ »
#
# U+FE0E (text presentation) keeps the glyphs as text, so the ANSI colour
# applies instead of a colour emoji. The glyph stays outside \[ \]: bash counts
# it as one column, the line editing keeps its place.
if [[ $- == *i* ]]; then
    if [ "$EUID" = 0 ]; then
        PS1='\[\e[1;31m\]\u\[\e[0m\]@\[\e[38;2;255;135;0m\]\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\] \[\e[1;32m\]☏︎\[\e[0m\] '
    else
        PS1='\[\e[1;36m\]\u\[\e[0m\]@\[\e[38;2;255;135;0m\]\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\] \[\e[1;31m\]☎︎\[\e[0m\] '
    fi
    # the terminal title: user@host: path
    PS1="\[\e]0;\u@\h: \w\a\]$PS1"
fi
