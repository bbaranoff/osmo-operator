# tools/softsim/ruby_compat.rb - shim pour softSIM (gitea.osmocom.org/sim-card/softsim)
# sous Ruby >= 3.2 : File.exists? et Fixnum/Bignum ont ete supprimes. Charge avec
#   ruby -r/usr/local/share/softsim/ruby_compat.rb demo_server.rb ...
# Ne modifie pas le depot softSIM.
class File
  def self.exists?(p) = exist?(p)
end
Fixnum = Integer unless defined?(Fixnum)
Bignum = Integer unless defined?(Bignum)
