# /etc/osmo-invite.bash - the bench prompt (configs/bash/osmo-invite.bash).
#
# Sourced LAST by ~/.bashrc (one line added by iso_modules/86-finitions.sh and
# update.sh), so it wins over the Ubuntu prompt and the older blocks.
#
#   root, /home open     user in RED: the owner's root, its state in the
#                        encrypted volume
#   root, GUEST          user in GREEN: the session opened without the /home
#                        passphrase - nothing personal at hand, all in RAM
#   the others           user in bold DARK BLUE (the session account)
#   host                 ORANGE, BOLD
#   path blue, then a telephone: GREEN, OFF THE HOOK for root (the line is
#   open), RED, HUNG UP for the others
#
# U+FE0E (text presentation) keeps the glyphs as text, so the ANSI colour
# applies instead of a colour emoji. The glyph stays outside \[ \]: bash counts
# it as one column, the line editing keeps its place.
if [[ $- == *i* ]]; then
    _oi_h='\[\e[1;38;2;255;135;0m\]\h\[\e[0m\]'
    if [ "$EUID" = 0 ]; then
        # guest: an encrypted /home is configured and it is not open
        _oi_u='\[\e[1;31m\]'
        if ( . /etc/default/crypthome 2>/dev/null; [ -n "${CRYPTHOME_UUID:-}" ] && ! mountpoint -q "${CRYPTHOME_MOUNT:-/home}" ); then
            _oi_u='\[\e[1;32m\]'
        fi
        PS1="$_oi_u"'\u\[\e[0m\]@'"$_oi_h"':\[\e[1;34m\]\w\[\e[0m\] \[\e[1;32m\]☏︎\[\e[0m\] '
    else
        PS1='\[\e[1;38;2;0;60;200m\]\u\[\e[0m\]@'"$_oi_h"':\[\e[1;34m\]\w\[\e[0m\] \[\e[1;31m\]☎︎\[\e[0m\] '
    fi
    unset _oi_h _oi_u
    # the terminal title: user@host: path
    PS1="\[\e]0;\u@\h: \w\a\]$PS1"
fi
