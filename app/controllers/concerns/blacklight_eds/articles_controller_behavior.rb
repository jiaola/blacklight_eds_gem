module BlacklightEds::ArticlesControllerBehavior
  extend ActiveSupport::Concern

  included do
    helper_method :eds_num_limiters, :eds_info, :eds_fulltext_links
  end

  def html_unescape(text)
    return CGI.unescape(text)
  end

  ###########
  # API Interaction
  ###########

  def eds_connect profile='default'
    unless eds_session[:connection] and eds_session[:profile] == profile
      # creates EDS API connection object, initializing it with application login credentials
      connection = EDSApi::ConnectionHandler.new(2)
      account = eds_profile profile
      is_guest = current_user ? 'n' : 'y'
      connection.uid_init(account['username'], account['password'], account['profile'], is_guest)
      Rails.cache.delete_matched('eds_auth_token/*') # clean up the cache
      eds_session.delete :session_key
      eds_session[:profile] = profile
      eds_session[:connection] = connection
    end
  end

  # Returns the connection object when called
  def eds_connection
    eds_session[:connection]
  end

  # Returns a profile. If the profile param is null, return the first profile
  def eds_profile profile=nil
    profiles = Blacklight5::Application.config.eds_profiles
    profiles.fetch(profile, profiles.values[0])
  end

  # Returns EDS auth_token. It's stored in Rails Low Level Cache, and expires in every 30 minutes
  def eds_auth_token
    cache_key = current_user ? 'eds_auth_token/user' : 'eds_auth_token/guest'
    auth_token = Rails.cache.fetch(cache_key, expires_in: 30.minutes) do
      eds_connection.uid_authenticate :json
      eds_connection.show_auth_token
    end
    logger.tagged('EDS') {
      logger.debug 'eds auth token: ' << auth_token
    }
    auth_token
  end

  def eds_session_key
    if current_user
      if eds_session[:user] != current_user.id
        eds_session[:user] = current_user.id
        eds_session[:session_key] = eds_connection.create_session eds_auth_token
      end
    else
      if eds_session[:user] != 'guest'
        eds_session[:user] = 'guest'
        eds_session[:session_key] = eds_connection.create_session eds_auth_token
      end
    end
    eds_session[:session_key] ||= eds_connection.create_session eds_auth_token
    logger.tagged('EDS') {
      logger.debug 'eds session_key: ' << eds_session[:session_key]
    }
    eds_session[:session_key]
  end

  def eds_info
    eds_session[:info] ||= eds_connection.info(eds_session_key, eds_auth_token, :json).to_hash
  end

  def eds_num_limiters
    eds_session[:num_limiters] = eds_info.fetch('AvailableSearchCriteria', {}).fetch('AvailableLimiters', nil)
                                     .count{|limiter| limiter['Type'] == 'select'}
  end

  # after basic functions like SEARCH, INFO, and RETRIEVE, check to make sure a new session token wasn't generated
  # if it was, use the new session key from here on out
  def check_session_currency
    if eds_connection.show_session_token != eds_session_key  # reset values. They'll be populated next time called
      [:session_key, :info, :num_limiters].each { |k| eds_session.delete(k) }
    end
  end

  # generates parameters for the API call given URL parameters
  # options is usually the params hash
  # this function strips out unneeded parameters and reformats them to form a string that the API accepts as input
  def generate_api_query(options)
    #translate Blacklight search_field into query index
    if options["search_field"].present?
      if options["search_field"] == "author"
        fieldcode = "AU:"
      elsif options["search_field"] == "subject"
        fieldcode = "SU:"
      elsif options["search_field"] == "title"
        fieldcode = "TI:"
      else
        fieldcode = ""
      end
    else
      fieldcode = ""
    end

    #should write something to allow this to be overridden
    searchmode = "AND"

    #build 'query-1' API URL parameter
    searchquery_extras = searchmode + "," + fieldcode

    #filter to make sure the only parameters put into the API query are those that are expected by the API
    edsKeys = ["eds_action", "q", "query-1", "facetfilter[]", "facetfilter", "sort", "includefacets", "searchmode", "view", "resultsperpage", "sort", "pagenumber", "highlight", "limiter", "limiter[]"]
    edsSubset = {}
    options.except(:action, :controller, :utf8).each do |key, value|
      if edsKeys.include?(key)
        edsSubset[key] = value
      end
    end

    #rename parameters to expected names
    #action and query-1 were renamed due to Rails and Blacklight conventions respectively
    mappings = {"eds_action" => "action", "q" => "query-1"}
    newoptions = Hash[edsSubset.map { |k, v| [mappings[k] || k, v] }]

    #repace the raw query, adding searchmode and fieldcode
    changedQuery = searchquery_extras.to_s + newoptions["query-1"].to_s
    #eds_session[:debugNotes << "CHANGEDQUERY: " << changedQuery.to_s
    newoptions["query-1"] = changedQuery

    #    uri = Addressable::URI.new
    #    uri.query_values = newoptions
    #    searchquery = uri.query
    #    debugNotes << "SEARCH QUERY " << searchquery.to_s
    #    searchtermindex = searchquery.index('query-1=') + 8
    #    searchquery.insert searchtermindex, searchquery_extras

    searchquery = newoptions.to_query
    # , : ( ) - unencoding expected punctuation
    #eds_session[:debugNotes << "<p>SEARCH QUERY AS STRING: " << searchquery.to_s
    #    searchquery = CGI::unescape(searchquery)
    #    #eds_session[:debugNotes << "<br />ESCAPED: " << searchquery.to_s
    searchquery = searchquery.gsub('limiter%5B%5D', 'limiter').gsub('facetfilter%5B%5D', 'facetfilter')
    searchquery = searchquery.gsub('%28', '(').gsub('%3A', ':').gsub('%29', ')').gsub('%23', ',')
    #    searchquery = searchquery.gsub(':','%3A')
    #eds_session[:debugNotes << "<br />FINAL: " << searchquery.to_s << "</p>"
    return searchquery
  end

  # main search function.  accepts string to be tacked on to API endpoint URL
  def eds_search(apiquery)
    #eds_session[:debugNotes << "<p>API QUERY SENT: " << apiquery.to_s << "</p>"
    results = eds_connection.search(apiquery, eds_session_key, eds_auth_token, :json).to_hash

    #update session_key if new one was generated in the call
    check_session_currency

    results
  end

  def eds_retrieve(dbid, an, highlight = "")
    #eds_session[:debugNotes << "HIGHLIGHTBEFORE:" << highlight.to_s
    highlight.downcase!
    highlight.gsub! ',and,', ','
    highlight.gsub! ',or,', ','
    highlight.gsub! ',not,', ','
    #eds_session[:debugNotes << "HIGHLIGHTAFTER: " << highlight.to_s
    record = eds_connection.retrieve(dbid, an, highlight, eds_session_key, eds_auth_token, :json).to_hash
    #eds_session[:debugNotes << "RECORD: " << record.to_s
    #update session_key if new one was generated in the call
    check_session_currency

    record
  end

  def termsToHighlight(terms = "")
    if terms.present?
      words = terms.split(/\W+/)
      return words.join(",").to_s
    else
      return ""
    end
  end

  # helper function for iterating through results from
  def switch_link(params, qurl)

    # check to see if the user is navigating to a record that was not included in the current page of results
    # if so, run a new search API call, getting the appropriate page of results
    if params[:resultId].to_i > (params[:pagenumber].to_i * params[:resultsperpage].to_i)
      nextPage = params[:pagenumber].to_i + 1
      newParams = params
      newParams[:eds_action] = "GoToPage(" + nextPage.to_s + ")"
      options = generate_api_query(newParams)
      search(options)
    elsif params[:resultId].to_i < (((params[:pagenumber].to_i - 1) * params[:resultsperpage].to_i) + 1)
      nextPage = params[:pagenumber].to_i - 1
      newParams = params
      newParams[:eds_action] = "GoToPage(" + nextPage.to_s + ")"
      options = generate_api_query(newParams)
      search(options)
    end

    link = ""
    # generate the link for the target record
    if @results['SearchResult']['Data']['Records'].present?
      @results['SearchResult']['Data']['Records'].each do |result|
        nextId = show_resultid(result).to_s
        if nextId == params[:resultId].to_s
          nextAn = show_an(result).to_s
          nextDbId = show_dbid(result).to_s
          nextrId = params[:resultId].to_s
          nextHighlight = params[:q].to_s
          link = request.fullpath.split("/switch")[0].to_s + "/" + nextDbId.to_s + "/" + nextAn.to_s + "/?resultId=" + nextrId.to_s + "&highlight=" + nextHighlight.to_s
        end
      end
    end
    return link.to_s

  end

  def get_num_limiters(info)
    avai_limiters = info.fetch('AvailableSearchCriteria', {}).fetch('AvailableLimiters', nil)
    avai_limiters.count{|limiter| limiter['Type'] == 'select'}
  end

  ############
  # File / Token Handling / End User Auth
  ############

  def clear_session_key
    session.delete(:session_key)
  end

  def getAuthToken
    eds_connection.uid_authenticate(:json)
    eds_connection.show_auth_token
  end


  ############
  # Linking Utilities
  ############

  #for the search form at the top of results
  #retains some of current search's fields (limiters)
  #discards pagenumber, facets and filters, actions, etc.
  def show_hidden_field_tags
    hidden_fields = "";
    params.except(:search_field, :fromDetail, :facetfilter, :pagenumber, :q, :dbid, :an, :fulltext_type) do |key, value|
      if key == :eds_action
        if value =~ /addlimiter/ or value =~ /removelimiter/ or value =~ /setsort/ or value =~ /SetResultsPerPage/
          hidden_fields << '<input type="hidden" name="' << key.to_s << '" value="' << value.to_s << '" />'
        end
      elsif value.kind_of?(Array)
        value.each do |v|
          hidden_fields << '<input type="hidden" name="' << key.to_s << '[]" value="' << v.to_s << '" />'
        end
      else
        hidden_fields << '<input type="hidden" name="' << key.to_s << '" value="' << value.to_s << '" />'
      end
    end
    hidden_fields.html_safe
  end

  def eds_fulltext_links(result, types)
    result.fetch('FullText', {}).fetch('Links', []).select { |link|
      types.include? link['Type']
    }
  end

  ################
  # Debug Functions
  ################

  def show_query_string
    return @results['queryString']
  end

  def debugNotes
    return #eds_session[:debugNotes << "<h4>API Calls</h4>" << @connection.debug_notes
  end


  def has_search_parameters?
    !params[:q].blank? or !params[:f].blank? or !params[:search_field].blank?
  end

  # preview and next ---------------------------------------

  def start_new_search_session?
    action_name == 'index'
  end

  def update_results_in_session results
    eds_session[:results] = results.fetch('SearchResult', {}).fetch('Data', {}).fetch('Records', []).map { |r|
      { an: r.fetch('Header', {}).fetch('An', nil), dbid: r.fetch('Header', {}).fetch('DbId', nil) }
    }
    eds_session[:query_string] = results.fetch('SearchRequestGet', {}).fetch('QueryString', nil)
    eds_session[:total_hits] = results.fetch('SearchResult', {}).fetch('Statistics', {}).fetch('TotalHits', -1)
  end
end
