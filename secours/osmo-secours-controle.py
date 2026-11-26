# osmo-secours-controle.py - les controles de la cle de secours (etape 1),
# avec l osmo-empreinte du DEPOT applique au disque monte en lecture seule.
import importlib.machinery, multiprocessing, os, sys, types
# Python 3.14 (Alpine) demarre ses processus par « forkserver », qui relit le
# programme principal depuis un fichier : la methode d Ubuntu (fork) ici aussi
multiprocessing.set_start_method("fork", force=True)
sortie = sys.argv[1]
open(os.path.join(sortie, "verdict"), "w").write("inacheve\n")
l = importlib.machinery.SourceFileLoader("emp", "/usr/local/sbin/osmo-empreinte")
m = types.ModuleType("emp"); m.__file__ = l.path
sys.modules["emp"] = m          # ses fonctions passent aux processus de hachage
l.exec_module(m)
V, R, J, F = "\033[1;32m  ok\033[0m  ", "\033[1;31m  !!\033[0m  ", "\033[1;33m  ??\033[0m  ", "\033[0m"
ko = 0

s = m.signature_ok()
if s is True: print(V + "empreinte du disque : signee par la phrase de /home")
elif s is None: print(J + "empreinte jamais signee")
else: print(R + "EMPREINTE NON SIGNEE ou signature fausse : elle ne prouve plus rien"); ko = 1

anc, pub = m.ancre_lue(), m.pub_empreinte()
if anc is None: print(J + "ancre TPM non lue (pas de TPM, ou jamais posee)")
elif anc == pub: print(V + "cle de signature : celle ancree dans le TPM")
else: print(R + "LA CLE DE SIGNATURE N EST PAS CELLE DU TPM : la paire de cles a ete remplacee"); ko = 1

t = m.tete_controler(parle=False)
if t == 0: print(V + "boite noire : sa fin est celle que le TPM a vue s ecrire")
elif t == 2: print(J + "boite noire : sa fin n est pas tenue par le TPM")
else: print(R + "BOITE NOIRE TRONQUEE OU REECRITE (differe du TPM)"); ko = 1

if os.path.exists(m.ALARME):
    print(R + "marque d ALARME sur la boite : " + open(m.ALARME).read().strip()); ko = 1
else:
    print(V + "pas de marque d alarme")
try:
    v = m.fin_controle()
    if v is not None:
        print((V + "derniere session persistante finie avec la phrase") if v[1] else
              (J + "derniere session persistante finie SANS la phrase (%s)" % m._date_enregistrement(v[0])))
except Exception:
    pass

print("\n\033[1;37;44m  Le contenu du disque systeme, relu en entier  \033[0m")
print("  (compare a l empreinte signee ; quelques minutes)")
ref, diffs = m.comparer("racine", m.RACINE, complet=True)
if ref is None:
    print(R + "pas d empreinte du disque sur la boite noire : rien a quoi comparer"); ko = 1
    diffs = []
elif not diffs:
    print(V + "DISQUE SYSTEME CONFORME a son empreinte signee (%s, %s entrees)" % (ref.get("pris"), ref.get("entrees", "?")))
else:
    print(R + "COMPROMISSION : %d difference(s) avec l empreinte signee du %s" % (len(diffs), ref.get("pris")))
    with open(os.path.join(sortie, "compromission.txt"), "w") as f:
        for k, p, d in diffs:
            f.write("%-9s /%s%s\n" % (k, p, ("  (%s)" % d) if d else ""))
    for k, p, d in diffs[:40]:
        print(("    %-9s /%s%s" % (k, p, ("  (%s)" % d) if d else ""))[:118])
    if len(diffs) > 40:
        print("    ... et %d autre(s) : %s/compromission.txt" % (len(diffs) - 40, sortie))
    ko = 1
open(os.path.join(sortie, "verdict"), "w").write("compromis\n" if ko else "conforme\n")
