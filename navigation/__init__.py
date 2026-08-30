# ss7console - console SS7 de osmo_egprs.
#
# Le paquet est volontairement sans dependance : rien que la bibliotheque
# standard de Python 3. Il tourne sur l'HOTE, et parle au lab par deux
# chemins complementaires :
#
#   - les VTY Osmocom, atteints par "docker exec" (les VTY n'ecoutent que sur
#     la boucle locale DU NOEUD) - lecture et pilotage des demons ;
#   - un vrai lien M3UA/SCTP vers l'inter-STP, qui fait de la console un point
#     SS7 a part entiere : elle peut emettre du TCAP/MAP (sendRoutingInfo,
#     sendRoutingInfoForSM, anyTimeInterrogation...) et lire les reponses.
#
# Toute la topologie est HERITEE des configurations du depot et des noeuds :
# aucun point code, aucune adresse, aucun port n'est ecrit en dur ici.
__version__ = "1.0"
