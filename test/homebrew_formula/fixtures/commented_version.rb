class Bondi < Formula
  desc "Bondi CLI"
  homepage "https://github.com/puravida-software/bondi"
  # version "0.25.0" # update on release

  on_linux do
    url "https://github.com/puravida-software/bondi/releases/download/v#{version}/bondi-linux-x86_64.tar.gz"
    sha256 "9175689fea6c734e057a3cc1ef592d92e9dc35b9e8072feeb1e06f04a50504e4"
  end

  def install
    bin.install "bondi"
  end
end
