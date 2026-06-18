# frozen_string_literal: true

require "prism"

module MrubyLsp
  class Document
    attr_reader :uri, :text, :ast, :version

    def initialize(uri, text, version = 1)
      @uri = uri
      @text = text
      @version = version
      @ast = Prism.parse(text)
    end

    def update(text, version)
      @text = text
      @version = version
      @ast = Prism.parse(text)
    end
  end

  class DocumentStore
    def initialize
      @documents = {}
    end

    def open(uri, text, version = 1)
      @documents[uri] = Document.new(uri, text, version)
    end

    def close(uri)
      @documents.delete(uri)
    end

    def get(uri)
      @documents[uri]
    end

    def all
      @documents.values
    end

    def each_uri(&block)
      @documents.keys.each(&block)
    end

    def empty?
      @documents.empty?
    end
  end
end
