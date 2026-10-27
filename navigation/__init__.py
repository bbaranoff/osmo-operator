# ss7console - the osmo-operator SS7 console.
#
# The package has no dependency beyond the Python 3 standard library. It runs
# on the HOST and talks to the lab through two complementary paths:
#
#   - the Osmocom VTYs, reached through "docker exec" (the VTYs only listen on
#     the NODE's loopback) - reading and driving the daemons;
#   - a real M3UA/SCTP link to the inter-STP, which makes the console a full
#     SS7 point: it can send TCAP/MAP (sendRoutingInfo, sendRoutingInfoForSM,
#     anyTimeInterrogation...) and read the answers.
#
# The whole topology is INHERITED from the repository and node configurations:
# no point code, address or port is hard-coded here.
__version__ = "1.0"
