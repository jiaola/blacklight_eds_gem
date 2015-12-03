require 'ebsco-discovery-service-api'
require_dependency "blacklight_eds/application_controller"

class BlacklightEds::ArticlesController < BlacklightEds::ApplicationController
  include BlacklightEds::Articles
  include Blacklight::Catalog::SearchContext

  helper_method :search_action_url
  helper_method :path_for_eds_article

  # to override any method in this class, create a new module, and include it in the extended controller class
end
