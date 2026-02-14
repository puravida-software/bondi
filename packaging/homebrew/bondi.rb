# typed: false
# frozen_string_literal: true

class Bondi < Formula
    desc "Bondi CLI - deployment and orchestration tool"
    homepage "https://github.com/puravida-software/bondi"
    version "0.0.0"
    license "MIT"

    on_linux do
      on_intel do
        url "https://github.com/puravida-software/bondi/releases/download/v#{version}/bondi-linux-x86_64.tar.gz"
        sha256 "0000000000000000000000000000000000000000000000000000000000000000"
      end
    end

    # on_macos do
    #   on_arm do
    #     url "https://github.com/puravida-software/bondi/releases/download/v#{version}/bondi-macos-arm64.tar.gz"
    #     sha256 "0000000000000000000000000000000000000000000000000000000000000000"
    #   end
    # end

    def install
      bin.install "bondi"
    end

    test do
      system "#{bin}/bondi", "--version"
    end
  end
