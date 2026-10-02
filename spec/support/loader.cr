require "../../src/configuration/loader"

def loader_for(yaml : String) : Configuration::Loader
  path = File.tempname("hk3s-spec", ".yaml")
  File.write(path, yaml)
  Configuration::Loader.new(path, nil, false)
end
