# quickcmd.py - les commandes VTY qui servent tous les jours, par demon.
# Elles alimentent le menu "commandes rapides" de la console : on choisit a la
# fleche, la sortie s'affiche, et on reste dans le schema.

QUICK = {
    "OsmoSTP": [
        ("AS (application servers)", "show cs7 instance 0 as all"),
        ("ASP (points d'acces)", "show cs7 instance 0 asp"),
        ("Table de routage", "show cs7 instance 0 route"),
        ("Utilisateurs SCCP", "show cs7 instance 0 users"),
        ("Connexions SCCP", "show cs7 instance 0 sccp connections"),
        ("SSN locaux", "show cs7 instance 0 sccp ssn"),
    ],
    "OsmoMSC": [
        ("Abonnes en VLR", "show subscriber cache"),
        ("Connexions actives", "show connection"),
        ("Transactions", "show transaction"),
        ("Liens BSC", "show bsc"),
        ("Statistiques", "show statistics"),
    ],
    "OsmoHLR": [
        ("Connexions GSUP (VLR/SMSC)", "show gsup-connections"),
        ("Statistiques", "show stats"),
    ],
    "OsmoBSC": [
        ("Etat des BTS", "show bts"),
        ("Canaux logiques", "show lchan"),
        ("Canaux occupes", "show lchan summary"),
        ("Liens vers le MSC", "show msc connection"),
        ("Timeslots", "show timeslot"),
    ],
    "OsmoBTS": [
        ("Etat du BTS", "show bts 0"),
        ("Canaux logiques", "show lchan summary"),
        ("Liens PHY", "show phy"),
    ],
    "OsmoMGW": [
        ("Points d'extremite", "show mgcp"),
        ("Statistiques", "show mgcp stats"),
    ],
    "OsmoSGSN": [
        ("Abonnes GPRS", "show subscriber cache"),
        ("Contextes PDP", "show pdp-context all"),
        ("Liens BSSGP", "show ns"),
    ],
    "OsmoGGSN": [
        ("Contextes PDP", "show pdp-context all"),
        ("APN", "show apn"),
    ],
    "OsmoPCU": [
        ("Etat TBF", "show tbf all"),
        ("BTS PCU", "show bts"),
    ],
    "OsmoSIPConnector": [
        ("Appels en cours", "show calls"),
        ("Statistiques", "show stats"),
    ],
    "OsmoMobile": [
        ("Etat du mobile", "show ms"),
        ("Reseaux vus", "show subscriber"),
    ],
}

DEFAULT = [
    ("Version", "show version"),
    ("Journal en cours", "show logging vty"),
    ("Configuration en vigueur", "show running-config"),
]


def for_daemon(daemon):
    return QUICK.get(daemon, []) + DEFAULT
