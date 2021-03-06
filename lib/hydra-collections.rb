require "hydra/head"
require 'hydra/works'

module Hydra
  module Collections
    extend ActiveSupport::Autoload
    autoload :Version
    autoload :SearchService
    autoload :AcceptsBatches

    class Engine < ::Rails::Engine
      engine_name "collections"
    end
  end
end
