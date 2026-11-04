# frozen_string_literal: true

require 'pikuri-core'

# Turns the +@path+ tokens in a prompt line into images for the model, leaving
# each file's name in the text so a sentence about two images still says which
# is which:
#
#   text, images = Shared::AttachmentTokens.split("compare @a.png with @'/tmp/my b.png'")
#   text    # => "compare a.png with my b.png"
#   images  # => [#<data Pikuri::Attachment filename="a.png" ...>, #<data ... filename="my b.png" ...>]
#
# A token is +@+ at the start of the line or after whitespace, then a path:
# bare (backslash escapes a space), or single- / double-quoted — the forms a
# terminal pastes for a dragged file. A +@word+ that names no file and doesn't
# look like a path (no +/+, no image extension) stays text, so +@alice+ is
# still a mention; one that does look like a path raises, so a typo never
# drops an image the user believes was sent. Punctuation trailing a bare token
# (+"see @shot.png, please"+) belongs to the sentence.
#
# {.token} goes the other way, building a checked token from a path for
# +/image+ to put in the prompt. Every refusal is an {Error} whose message is
# ready to show the user.
module Shared::AttachmentTokens
  # A token that names a path which can't be attached. The line it came from
  # should not be sent.
  class Error < StandardError; end

  # The cap on one image, matching the +read+ tool's.
  #
  # @return [Integer]
  MAX_BYTES = 5 * 1024 * 1024

  # The formats both the vision models and {Pikuri::FileType.detect_mime} know.
  #
  # @return [Array<String>]
  MIMES = %w[image/png image/jpeg image/gif image/webp].freeze

  # @return [Regexp]
  TOKEN = /(?<=\A|\s)@(?:'([^']*)'|"([^"]*)"|((?:\\.|\S)+))/
  # @return [Regexp]
  IMAGE_EXTENSION = /\.(png|jpe?g|gif|webp)\z/i
  # @return [Regexp]
  TRAILING_PUNCTUATION = /[.,;:!?)\]]+\z/
  private_constant :TOKEN, :IMAGE_EXTENSION, :TRAILING_PUNCTUATION

  # Splits +line+ into the text to send and the images its tokens name, each
  # file read once.
  #
  # @param line [String] the prompt as typed.
  # @return [Array(String, Array<Pikuri::Attachment>)] the text with every
  #   attached token replaced by its file's basename, and the images in token
  #   order.
  # @raise [Error] on a path-like token that names no file, or a file that is
  #   too big or not a PNG, JPEG, GIF or WebP image.
  def self.split(line)
    attachments = []
    text = line.gsub(TOKEN) do
      match = Regexp.last_match
      quoted = match[1] || match[2]
      raw, tail = quoted ? [quoted, ''] : split_tail(match[3].gsub(/\\(.)/, '\1'))
      path = expand(raw)
      if File.file?(path)
        attachments << load(path)
        "#{File.basename(path)}#{tail}"
      elsif raw.include?('/') || raw.match?(IMAGE_EXTENSION)
        raise Error, "No such file: #{raw}"
      else
        match[0]
      end
    end
    [text, attachments]
  end

  # Checks the file +arg+ names and returns the token that attaches it, quoted
  # when the path needs it — what +/image <path>+ puts in the prompt:
  #
  #   token("/tmp/shot.png")         # => "@/tmp/shot.png"
  #   token("'/tmp/my shot.png'")    # => "@'/tmp/my shot.png'"   (a dragged file)
  #   token("/tmp/my shot.png")      # => "@'/tmp/my shot.png'"   (unquoted: the whole arg is the path)
  #
  # @param arg [String] one path, bare, quoted or backslash-escaped.
  # @return [String] a token {.split} attaches the same file from.
  # @raise [Error] on a blank +arg+, or a file {.split} would refuse.
  def self.token(arg)
    path = unquote(arg.strip)
    raise Error, 'Usage: /image <path>' if path.empty?

    full = expand(path)
    raise Error, "No such file: #{path}" unless File.file?(full)

    load(full)
    return "@#{path}" unless path.match?(/[\s'"\\]/)

    path.include?("'") ? "@#{path.gsub(/([\s'"\\])/, '\\\\\1')}" : "@'#{path}'"
  end

  # @param arg [String] a path, maybe wrapped in matching quotes.
  # @return [String] the path with its quotes or backslash escapes removed.
  def self.unquote(arg)
    arg[/\A'(.*)'\z/m, 1] || arg[/\A"(.*)"\z/m, 1] || arg.gsub(/\\(.)/, '\1')
  end
  private_class_method :unquote

  # Peels sentence punctuation off a bare token, unless the file's name really
  # ends in it.
  #
  #   split_tail('shot.png,')   # => ["shot.png", ","]
  #
  # @param raw [String] an unquoted token's path, escapes resolved.
  # @return [Array(String, String)] the path and the punctuation behind it.
  def self.split_tail(raw)
    return [raw, ''] if File.file?(expand(raw))

    tail = raw[TRAILING_PUNCTUATION].to_s
    [raw.delete_suffix(tail), tail]
  end
  private_class_method :split_tail

  # @param raw [String] a token's path, as typed.
  # @return [String] the absolute path; relative ones resolve against the
  #   process's working directory.
  # @raise [Error] on +~nosuchuser+.
  def self.expand(raw)
    File.expand_path(raw)
  rescue ArgumentError => e
    raise Error, e.message
  end
  private_class_method :expand

  # Reads +path+ once, so the model sees exactly the bytes that were checked.
  #
  # @param path [String] an existing file.
  # @return [Pikuri::Attachment]
  # @raise [Error] when it is unreadable, over {MAX_BYTES}, or not one of {MIMES}.
  def self.load(path)
    bytes = File.binread(path, MAX_BYTES + 1) || ''.b
    name = File.basename(path)
    raise Error, "#{name} is over #{Pikuri::Tool.format_bytes(MAX_BYTES)}" if bytes.bytesize > MAX_BYTES

    mime = Pikuri::FileType.detect_mime(bytes)
    raise Error, "#{name} is not a PNG, JPEG, GIF or WebP image" unless MIMES.include?(mime)

    Pikuri::Attachment.new(mime: mime, filename: name, bytes: bytes)
  rescue SystemCallError => e
    raise Error, "Can't read #{path}: #{e.message}"
  end
  private_class_method :load
end
