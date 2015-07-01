require 'blacklight'

module BlacklightEds::Articles
  extend ActiveSupport::Concern
  extend ActiveSupport::Autoload

  included do
    helper_method :search_action_url
  end

  def index
    api_query = generate_api_query params

    if has_search_parameters?
      @results = eds_search api_query
      update_results_in_session @results
      eds_session[:api_query] = api_query
    end
  end

  def show
    recordArray = eds_retrieve(params[:dbid].to_s,params[:an].to_s,termsToHighlight(params[:highlight]))

    if not eds_session.has_key? :results and eds_session.has_key? :api_query
      @results = eds_search eds_session[:api_query]
    end

    if recordArray['Record'].present?
      @record = recordArray['Record']
    end

    respond_to do |format|
      format.html
    end
  end

  def fulltext
    recordArray = eds_retrieve(params[:dbid].to_s,params[:an].to_s,termsToHighlight(params[:highlight]))
    if recordArray['Record'].present?
      record = recordArray['Record']
    end
    fulltext_links = eds_fulltext_links(record, params[:fulltext_type])
    if fulltext_links.empty?
      flash.now[:error] = 'Full text not found for this item'
    else
      redirect_to eds_fulltext_links(record, params[:fulltext_type])[0]['Url']
    end
  end

  def switch
    # check to see if the user is navigating to a record that was not included in the current page of results
    # if so, run a new search API call, getting the appropriate page of results
    next_id = params[:resultId].to_i
    if next_id > (params[:pagenumber].to_i * params[:resultsperpage].to_i)
      next_page = params[:pagenumber].to_i + 1
      new_params = params.dup
      new_params[:eds_action] = "GoToPage(" + next_page.to_s + ")"
    elsif next_id < (((params[:pagenumber].to_i - 1) * params[:resultsperpage].to_i) + 1)
      next_page = params[:pagenumber].to_i - 1
      new_params = params.dup
      new_params[:eds_action] = "GoToPage(" + next_page.to_s + ")"
    else
      next_page = params[:pagenumber].to_i
    end

    if new_params.present?
      api_query = generate_api_query(new_params)
      @results = eds_search api_query
      update_results_in_session @results
      eds_session[:api_query] = api_query
    end

    record_index = next_id.to_i - (next_page - 1) * params[:resultsperpage].to_i - 1
    next_record = eds_session[:results][record_index]

    next_an = next_record[:an]
    next_dbid = next_record[:dbid]
    next_highlight = params[:q]

    next_params = {dbid: next_dbid, an: next_an, resultId: next_id.to_s, hightlight: next_highlight}

    redirect_to path_for_eds_article dbid: next_dbid, an: next_an, resultId: next_id.to_s, hightlight: next_highlight
  end

  def search_action_url(*args)
    eds_articles_url *args
  end

end
