# The MIT License (MIT)

# Copyright (c) 2023 Mike DeAngelo Google, Inc.

# Permission is hereby granted, free of charge, to any person obtaining a copy of
# this software and associated documentation files (the "Software"), to deal in
# the Software without restriction, including without limitation the rights to
# use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
# the Software, and to permit persons to whom the Software is furnished to do so,
# subject to the following conditions:

# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
# FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
# COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
# IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
# CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

# frozen_string_literal: true

module Gzr
  module Look
    def query_look(look_id)
      begin
        @sdk.look(look_id).to_attrs
      rescue LookerSDK::NotFoud => e
          say_error "look(#{look_id}) not found"
          say_error e
          raise
      rescue LookerSDK::Error => e
          say_error "Error querying look(#{look_id})"
          say_error e
          raise
      end
    end

    def search_looks_by_slug(slug, folder_id=nil)
      data = []
      begin
        req = { :slug => slug }
        req[:folder_id] = folder_id if folder_id
        data = @sdk.search_looks(req).collect { |l| l.to_attrs }
        req[:deleted] = true
        data = @sdk.search_looks(req).collect { |l| l.to_attrs } if data.empty?
      rescue LookerSDK::Error => e
        say_error "Error search_looks_by_slug(#{JSON.pretty_generate(req)})"
        say_error e
        raise
      end
      data
    end

    def search_looks_by_title(title, folder_id=nil)
      data = []
      begin
        req = { :title => title }
        req[:folder_id] = folder_id if folder_id
        data = @sdk.search_looks(req).collect { |l| l.to_attrs }
        req[:deleted] = true
        data = @sdk.search_looks(req).collect { |l| l.to_attrs } if data.empty?
      rescue LookerSDK::Error => e
        say_error "Error search_looks_by_title(#{JSON.pretty_generate(req)})"
        say_error e
        raise
      end
      data
    end

    def create_look(look)
      begin
        look[:public] = false unless look[:public]
        @sdk.create_look(look).to_attrs
      rescue LookerSDK::Error => e
        say_error "Error creating look(#{JSON.pretty_generate(look)})"
        say_error e
        raise
      end
    end

    def update_look(id,look)
      begin
        @sdk.update_look(id,look).to_attrs
      rescue LookerSDK::NotFound => e
        say_error "look(#{id}) not found"
        say_error e
        raise
      rescue LookerSDK::Error => e
        say_error "Error updating look(#{id},#{JSON.pretty_generate(look)})"
        say_error e
        raise
      end
    end

    def delete_look(look_id)
      begin
        @sdk.delete_look(look_id)
      rescue LookerSDK::Error => e
        say_error "Error deleting look(#{look_id})"
        say_error e
        raise
      end
    end

    def upsert_look(user_id, query_id, folder_id, source, output: $stdout)
      # try to find look by slug in target folder
      existing_look = search_looks_by_slug(source[:slug], folder_id).fetch(0,nil) if source[:slug]
      # check for look of same title in target folder
      title_used = search_looks_by_title(source[:title], folder_id).fetch(0,nil)

      # If there is no match by slug in target folder or no slug given, then we match by title
      existing_look ||= title_used

      # same_title is now a flag indicating that there is already a look in the same folder with
      # that title, and it is the one we are updating.
      same_title = (title_used&.fetch(:id,nil) == existing_look&.fetch(:id,nil))

      # check if the slug is used by any look
      slug_used = search_looks_by_slug(source[:slug]).fetch(0,nil) if source[:slug]

      # same_slug is now a flag indicating that there is already a look with
      # that slug, but it is the one we are updating.
      same_slug = (slug_used&.fetch(:id,nil) == existing_look&.fetch(:id,nil))

      if slug_used && !same_slug then
        say_warning "slug #{slug_used[:slug]} already used for look #{slug_used[:title]} in folder #{slug_used[:folder_id]}", output: output
        say_warning("That look is in the 'Trash' but not fully deleted yet", output: output) if slug_used[:deleted]
        say_warning "look will be imported with new slug", output: output
      end

      if existing_look then
        if title_used && !same_title then
          raise Gzr::CLI::Error, "Look #{source[:title]} already exists in folder #{folder_id}\nDelete it before trying to upate another Look to have that title."
        end
        raise Gzr::CLI::Error, "Look #{existing_look[:title]} with slug #{existing_look[:slug]} already exists in folder #{folder_id}\nUse --force if you want to overwrite it" unless @options[:force]
        say_ok "Modifying existing Look #{existing_look[:id]} #{existing_look[:title]} in folder #{folder_id}", output: output
        new_look = source.select do |k,v|
          (keys_to_keep('update_look') - [:space_id,:folder_id,:user_id,:query_id,:slug]).include? k
        end
        new_look[:slug] = source[:slug] if source[:slug] && !slug_used
        new_look[:deleted] = false if existing_look[:deleted]
        new_look[:query_id] = query_id
        return update_look(existing_look[:id],new_look)
      else
        new_look = source.select do |k,v|
          (keys_to_keep('create_look') - [:space_id,:folder_id,:user_id,:query_id,:slug]).include? k
        end
        new_look[:slug] = source[:slug] unless slug_used
        new_look[:query_id] = query_id
        new_look[:user_id] = user_id
        new_look[:folder_id] = folder_id

        find_vis_config_reference(new_look) do |vis_config|
          find_color_palette_reference(vis_config) do |o,default_colors|
            update_color_palette!(o,default_colors)
          end
        end
        return create_look(new_look)
      end
    end

    def create_fetch_query(source_query)
      new_query = source_query.select do |k,v|
        (keys_to_keep('create_query') - [:client_id]).include? k
      end
      find_vis_config_reference(new_query) do |vis_config|
        find_color_palette_reference(vis_config) do |o,default_colors|
          update_color_palette!(o,default_colors)
        end
      end
      return create_query(new_query)
    end

    def create_merge_result(merge_result)
      new_merge_result = merge_result.select do |k,v|
        (keys_to_keep('create_merge_query') - [:client_id,:source_queries]).include? k
      end
      new_merge_result[:source_queries] = merge_result[:source_queries].map do |query|
        new_query = {}
        new_query[:query_id] = create_fetch_query(query[:query]).id
        new_query[:name] = query[:name]
        new_query[:merge_fields] = query[:merge_fields]
        new_query
      end
      find_vis_config_reference(new_merge_result) do |vis_config|
        find_color_palette_reference(vis_config) do |o,default_colors|
          update_color_palette!(o,default_colors)
        end
      end
      return create_merge_query(new_merge_result)
    end

    def cat_look(look_id)
      data = query_look(look_id)
      find_vis_config_reference(data) do |vis_config|
        find_color_palette_reference(vis_config) do |o,default_colors|
          rewrite_color_palette!(o,default_colors)
        end
      end

      data[:scheduled_plans] = query_scheduled_plans_for_look(@look_id,"all") if @options[:plans]
      data
    end

    def trim_look(data)
      trimmed = data.select do |k,v|
        (keys_to_keep('update_look') + [:id,:query]).include? k
      end
      trimmed[:query] = data[:query].select do |k,v|
        (keys_to_keep('create_query') + [:id]).include? k
      end

      trimmed[:scheduled_plans] = data[:scheduled_plans].map do |sp|
        sp.select do |k,v|
          (keys_to_keep('create_scheduled_plan') + [:id]).include? k
        end
      end if data[:scheduled_plans]

      trimmed
    end
  end
end
