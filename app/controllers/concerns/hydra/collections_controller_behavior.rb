module Hydra
  module CollectionsControllerBehavior
    extend ActiveSupport::Concern

    include Blacklight::Base
    include Hydra::Collections::SelectsCollections

    included do
      include Hydra::Collections::AcceptsBatches

      # This is needed as of BL 3.7
      self.copy_blacklight_config_from(CatalogController)


      # Catch permission errors
      rescue_from Hydra::AccessDenied, CanCan::AccessDenied do |exception|
        if exception.action == :edit
          redirect_to(collections.url_for({:action=>'show'}), :alert => "You do not have sufficient privileges to edit this document")
        elsif current_user and current_user.persisted?
          redirect_to root_url, :alert => exception.message
        else
          session["user_return_to"] = request.url
          redirect_to new_user_session_url, :alert => exception.message
        end
      end

      # actions: audit, index, create, new, edit, show, update, destroy, permissions, citation
      before_filter :authenticate_user!, :except => [:show]
      load_and_authorize_resource :except=>[:index], instance_name: :collection

      layout 'collections'
    end

    def index
      # run the solr query to find the collections
      query = collections_search_builder.with(params).query
      @response = repository.search(query)
      @document_list = @response.documents
    end

    def new
    end

    def show
      query_collection_members
    end

    def edit
      query_collection_members
      find_collections
    end

    def after_create
      respond_to do |format|
        ActiveFedora::SolrService.instance.conn.commit
        format.html { redirect_to collections.collection_path(@collection), notice: 'Collection was successfully created.' }
        format.json { render json: @collection, status: :created, location: @collection }
      end
    end

    def after_create_error
      respond_to do |format|
        format.html { render action: "new" }
        format.json { render json: @collection.errors, status: :unprocessable_entity }
      end
    end

    def create
      @collection.apply_depositor_metadata(current_user.user_key)
      add_members_to_collection unless batch.empty?
      if @collection.save
        after_create
      else
        after_create_error
      end
    end

    def after_update
      if flash[:notice].nil?
        flash[:notice] = 'Collection was successfully updated.'
      end
      respond_to do |format|
        format.html { redirect_to collections.collection_path(@collection) }
        format.json { render json: @collection, status: :updated, location: @collection }
      end
    end

    def after_update_error
      respond_to do |format|
        format.html { render action: "edit" }
        format.json { render json: @collection.errors, status: :unprocessable_entity }
      end
    end

    def update
      process_member_changes
      if @collection.update(collection_params.except(:members))
        after_update
      else
        after_update_error
      end
    end

    def after_destroy (id)
      respond_to do |format|
        format.html { redirect_to search_catalog_path, notice: 'Collection was successfully deleted.' }
        format.json { render json: {id:id}, status: :destroyed, location: @collection }
      end
    end

    def after_destroy_error (id)
      respond_to do |format|
        format.html { redirect_to search_catalog_path, notice: 'Collection could not be deleted.' }
        format.json { render json: {id:id}, status: :destroy_error, location: @collection }
      end
    end

    def destroy
      if @collection.destroy
         after_destroy(params[:id])
      else
        after_destroy_error(params[:id])
      end
    end

    def collection
      @collection
    end

    protected

    def collection_params
      params.require(:collection).permit(:part_of, :contributor, :creator,
        :publisher, :date_created, :subject, :language, :rights,
        :resource_type, :identifier, :based_near, :tag, :related_url, :members,
        title: [], description: [])
    end

    # Queries Solr for members of the collection.
    # Populates @response and @member_docs similar to Blacklight Catalog#index populating @response and @documents
    def query_collection_members
      @response = repository.search(query_for_collection_members)
      @member_docs = @response.documents
    end

    # @return <Hash> a representation of the solr query that find the collection members
    def query_for_collection_members
      collection_member_search_builder.with(params_for_members_query).query
    end

    # You can override this method if you need to provide additional inputs to the search
    # builder. For example:
    #   search_field: 'all_fields'
    # @return <Hash> the inputs required for the collection member search builder
    def params_for_members_query
      params.symbolize_keys.merge(q: params[:cq])
    end

    def collection_member_search_builder_class
      Hydra::Collections::MemberSearchBuilder
    end

    def collection_member_search_builder
      @collection_member_search_builder ||= collection_member_search_builder_class.new(self).tap do |builder|
        builder.current_ability = current_ability
      end
    end

    def process_member_changes
      case params[:collection][:members]
        when "add" then add_members_to_collection
        when "remove" then remove_members_from_collection
        when "move" then move_members_between_collections
        when Array then assign_batch_to_collection
      end
    end

    def add_members_to_collection collection = nil
      collection ||= @collection
      collection.add_members batch
    end

    def remove_members_from_collection
      @collection.members.delete(batch.map { |pid| ActiveFedora::Base.find(pid) })
    end

    def assign_batch_to_collection
      @collection.members(true) #Force the members to get cached before (maybe) removing some of them
      @collection.member_ids = batch
    end

    def move_members_between_collections
      destination_collection = ::Collection.find(params[:destination_collection_id])
      remove_members_from_collection
      add_members_to_collection(destination_collection)
      if destination_collection.save
        flash[:notice] = "Successfully moved #{batch.count} files to #{destination_collection.title} Collection."
      else
        flash[:error] = "An error occured. Files were not moved to #{destination_collection.title} Collection."
      end
    end

    # Override rails path for the views
    def _prefixes
      @_prefixes ||= super + ['catalog']
    end
  end # module CollectionsControllerBehavior
end # module Hydra
