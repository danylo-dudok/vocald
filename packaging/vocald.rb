# vocald — headless TTS/STT server (REST + MCP).
# Personal-tap formula installed from a LOCAL working-tree tarball:
#   verify-cli.sh builds dist/vocald.tar.gz, substitutes @TARBALL@ and
#   @SHA256@ below into dist/vocald.rb, then:
#     brew install --formula dist/vocald.rb
# Never published anywhere.
class Vocald < Formula
  desc "Headless TTS/STT server (REST + MCP): Kokoro on onnxruntime, Whisper on CTranslate2"
  homepage "https://github.com/jamiepine/voicebox"
  url "file://@TARBALL@"
  sha256 "@SHA256@"
  version "0.6.0"
  license "MIT"

  depends_on "python@3.12"

  def install
    venv = libexec
    system Formula["python@3.12"].opt_bin/"python3.12", "-m", "venv", venv
    # ponytail: plain pip into a libexec venv — no resources ceremony,
    # network during install is fine for a personal tap
    system venv/"bin/pip", "install", "--upgrade", "pip"
    system venv/"bin/pip", "install", buildpath
    # Binary wheels (PyAV etc.) ship read-only dylibs; brew's post-install
    # linkage fixup needs them writable or it aborts the whole install.
    system "chmod", "-R", "u+w", venv/"lib"
    bin.install_symlink venv/"bin/vocald-server"
    bin.install_symlink venv/"bin/voicebox-server"
  end

  def caveats
    <<~EOS
      Start the server:
        vocald-server                        # loopback dev mode, no auth
        VOICEBOX_API_KEY=$(openssl rand -hex 24) vocald-server
      Data (DB, audio, models) lives in ~/.voicebox by default.
      Kokoro model files (~115MB) download on first generation.
    EOS
  end

  test do
    system bin/"vocald-server", "--help"
  end
end
