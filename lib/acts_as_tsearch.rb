require 'active_record'
#require 'postgres_extensions'

module TsearchMixin
  module Acts #:nodoc:
    module Tsearch #:nodoc:

      def self.included(mod)
        mod.extend(ClassMethods)
      end

      # declare the class level helper methods which
      # will load the relevant instance methods
      # defined below when invoked
      module ClassMethods
        def tsearch_config
          @tsearch_config
        end

        def acts_as_tsearch(options = {})
          default_config = {:locale => "default", :auto_update_index => true}
          @tsearch_config = {}
          if !options.is_a?(Hash)
            raise "Missing required fields for acts_as_tsearch.  At a bare minimum you need :fields => 'SomeFileName'.  Please see
            documentation on http://acts-as-tsearch.rubyforge.org"
          else
            fields = []
            #they passed in :fields => "somefield" or :fields => [:one, :two, :three]
            #:fields => "somefield"
            if options[:fields].is_a?(String)
              @tsearch_config = {:vectors => default_config.clone}
              @tsearch_config[:vectors][:fields] = 
                {"a" => {:columns => [options[:fields]], :weight => 1.0}}
              fields << options[:fields]
            #:fields => [:one, :two]
            elsif options[:fields].is_a?(Array)
              @tsearch_config = {:vectors => default_config.clone}
              @tsearch_config[:vectors][:fields] = 
                {"a" => {:columns => options[:fields], :weight => 1.0}}
              fields = options[:fields]
            # :fields => {"a" => {:columns => [:one, :two], :weight => 1},
            #              "b" => {:colums => [:three, :four], :weight => 0.5}
            #              }
            elsif options[:fields].is_a?(Hash)
              @tsearch_config = {:vectors => default_config.clone}
              @tsearch_config[:vectors][:fields] = options[:fields]
              options[:fields].keys.each do |k|
                options[:fields][k][:columns].each do |f|
                  fields << f
                end
              end
            else
              # :vectors => {
              #   :auto_update_index => false,
              #   :fields => [:title, :description]
              # }
              options.keys.each do |k|
                @tsearch_config[k] = default_config.clone
                @tsearch_config[k].update(options[k])
                if options[k][:fields].is_a?(String)
                  fields << options[k][:fields]
                elsif options[k][:fields].is_a?(Array)
                  options[k][:fields].each do |f|
                    fields << f
                  end
                else
                  options[k][:fields].keys.each do |kk|
                    options[k][:fields][kk][:columns].each do |f|
                      fields << f
                    end
                  end
                end
                #TODO: add error checking here for complex fields - right know - assume it's correct
                #puts k.to_s + " yamled = " + @tsearch_config.to_yaml
              end
            end
            
            fields.uniq!
            #check to make sure all fields exist
            #TODO Write check code for multi-table... ignoring this for now
            missing_fields = []
            fields.each do |f|
              missing_fields << f.to_s unless column_names().include?(f.to_s) or f.to_s.include?(".")
            end
            raise ArgumentError, "Missing fields: #{missing_fields.sort.join(",")} in acts_as_tsearch definition for 
              table #{table_name}" if missing_fields.size > 0
          end
          
          class_eval do
            @@postgresql_version = connection.instance_variable_get('@postgresql_version')
            def self.postgresql_version
              @@postgresql_version
            end
            
            after_save :update_vector_row
          
            extend TsearchMixin::Acts::Tsearch::SingletonMethods
          end
          include TsearchMixin::Acts::Tsearch::InstanceMethods
        end
      end

      module SingletonMethods

        #Finds a tsearch2 formated query in the tables vector column and adds
        #tsearch_rank to the results
        #
        #Inputs:
        #   search_string:  just about anything.  If you want to run a tsearch styled query 
        #                   (see http://mira.sai.msu.su/~megera/pgsql/ftsdoc/fts-query.html for 
        #                   details on this) just set fix_query = false.  
        #
        #   options: standard ActiveRecord find options - see http://api.rubyonrails.com/classes/ActiveRecord/Base.html#M000989
        #
        #   headlines:  TSearch2 can generate snippets of text with words found highlighted.  Put in the column names 
        #               of any of the columns in your vector and they'll come back as "{column_name}_headline"
        #               These are pretty expensive to generate - so only use them if you need them.
        #               example:  pass this [%w{title description}]
        #                         get back this result.title_headline, result.description_headline
        #
        #   fix_query:  the default will automatically try to fix your query with the fix_tsearch_query function
        #
        #   locals:  TODO:  Document this... see
        #                  http://www.sai.msu.su/~megera/postgres/gist/tsearch/V2/docs/tsearch-V2-intro.html for details
        #
        #TODO:  Not sure how to handle order... current we add to it if it exists but this might not
        #be the right thing to do
        def find_by_tsearch(search_string, options = nil, tsearch_options = nil, page = 1, per_page = 10)
          raise "You must upgrade to Postgres 8.3 before using tsearch" unless is_postgresql_83?
          raise ActiveRecord::RecordNotFound, "Couldn't find #{name} without a search string" if search_string.nil? || search_string.empty?

          options = {} if options.nil?
          tsearch_options = {} if tsearch_options.nil?
          #assume vector column is named "vectors" unless otherwise specified
          tsearch_options[:vector] = "vectors" unless tsearch_options.keys.include?(:vector)
          raise "Vector [#{tsearch_options[:vector].intern}] not found 
                  in acts_as_tsearch config: #{@tsearch_config.to_yaml}
                  " if !@tsearch_config.keys.include?(tsearch_options[:vector].intern)
          tsearch_options[:fix_query] = true if tsearch_options[:fix_query].nil?

          locale = @tsearch_config[tsearch_options[:vector].intern][:locale]
          check_for_vector_column(tsearch_options[:vector])
          
          search_string = fix_tsearch_query(search_string) if tsearch_options[:fix_query] == true
          
          #add tsearch_rank to fields returned
          tsearch_rank_function = "ts_rank_cd(#{table_name}.#{tsearch_options[:vector]},tsearch_query#{','+tsearch_options[:normalization].to_s if tsearch_options[:normalization]})"

          select_part = "#{tsearch_rank_function} as tsearch_rank"
          if options[:select]
            if options[:select].downcase != "count(*)"
              options[:select] << ", #{select_part}"
            end
          else
            options[:select] = "#{table_name}.*, #{select_part}"
          end
#options[:select] << " o w w e"          
          #add headlines
          if tsearch_options[:headlines]
            tsearch_options[:headlines].each do |h|
              options[:select] << ", ts_headline(#{table_name}.#{h},tsearch_query) as #{h}_headline"
            end
          end
          
          #add tsearch_query to from
          from_part = "to_tsquery('#{search_string}') as tsearch_query"
          if options[:from]
            options[:from] = "#{from_part}, #{options[:from]}"
          else
            options[:from] = "#{from_part}, #{table_name}"
          end
          
          #add vector condition
          where_part = "#{table_name}.#{tsearch_options[:vector]} @@ tsearch_query"
          if options[:conditions] and options[:conditions].is_a? String
            options[:conditions] << " and #{where_part}"
          elsif options[:conditions] and options[:conditions].is_a? Array
            options[:conditions].first << " and #{where_part}"
          else
            options[:conditions] = where_part
          end
          order_part = "tsearch_rank desc"
          if !options[:order]
            # Note if the :include option to ActiveRecord::Base.find is used, the :select option is ignored
            # (in ActiveRecord::Associations.construct_finder_sql_with_included_associations),
            # so the 'tsearch_rank' function def above doesn't make it into the generated SQL, and the order
            # by tsearch_rank fails. So we have to provide that function here, in the order_by clause.
            options[:order] = (options.has_key?(:include) ? tsearch_rank_function : order_part)
          end
          
          #finally - return results
          find(:all, options).paginate(:page => page, :per_page => per_page)
          # find(:all,
          #   :select => "#{table_name}.*, rank_cd(blogger_groups.vectors, query) as rank",
          #   :from => "#{table_name}, to_tsquery('default','#{search_string}') as query",
          #   :conditions => "#{table_name}.vectors @@ query",
          #   :order => "rank_cd(#{table_name}.vectors, query)",
          #   :limit => 100)
        end
        

        def count_by_tsearch(search_string, options = {}, tsearch_options = {})
            options[:select] = "count(*)"
            options[:order] = "1 desc"
            find_by_tsearch(search_string, options, tsearch_options)[0][:count].to_i
        end        

        # Create a tsearch_query from a Google like query (and or " +)
        def fix_tsearch_query(query)
          terms = query_to_terms(clean_query(query))
          terms.flatten!
          terms.shift
          terms.join
        end
        
        # Convert a search query into an array of terms [prefix, term] where
        # Prefix is | or & (tsearch and/or) and term is a phrase (with or with negation)
        def query_to_terms(query)
          query.scan(/(\+|or \-?|and \-?|\-)?("[^"]*"?|[\w\-]+)/).collect do |prefix, term|
            term = "(#{term.scan(/[\w']+/).join('&')})" if term[0,1] == '"'
            term = "!#{term}" if prefix =~ /\-/
            [(prefix =~ /or/) ? '|' : '&', term] 
          end
        end
        
        def clean_query(query)
          query.gsub(/[^\w\-\+'"]+/, " ").gsub("'", "''").strip.downcase     
        end
        
        #checks to see if vector column exists.  if it doesn't exist, create it and update isn't index.
        def check_for_vector_column(vector_name = "vectors")
          #check for the basics
          if !column_names().include?(vector_name)
            raise "Table #{table_name} doesn't have a tsearch vector column. Do you need to migrate?"
          end
        end
        
        def update_vectors(row_id = nil)
          @tsearch_config.keys.each do |k|
            update_vector(row_id, k.to_s)
          end
        end
        
        #This will update the vector colum for all rows (unless a row_id is passed).  If you think your indexes are screwed
        #up try running this.  This get's called by the callback after_update when you change your model.
        # Sample SQL
        #   update 
        # 	  blog_entries
        #   set 
        # 	  vectors = to_tsvector('default',
        #   coalesce(blog_entries.title,'') || ' ' || coalesce(blog_comments.comment,'')
        #   )
        #   from
        # 	  blog_entries b2 left outer join blog_comments on b2.id = blog_comments.blog_entry_id
        #   where b2.id = blog_entries.id
        #
        # Sample call
        #   BlogEntry.acts_as_tsearch :vectors => {
        #           :fields => {
        #               "a" => {:columns => ["blog_entry.title"], :weight => 1},
        #               "b" => {:columns => ["blog_comments.comment"], :weight => 0.5}
        #             },
        #           :tables => {
        #               :blog_comments => {
        #                 :from => "blog_entries b2 left outer join blog_comments on blog_comments.blog_entry_id = b2.id",
        #                 :where => "b2.id = blog_entries.id"
        #                 }
        #             }
        #           }
        def update_vector(row_id = nil, vector_name = "vectors")
          sql = ""
          if !column_names().include?(vector_name)
            raise "Table #{table_name} doesn't have a tsearch vector column. Do you need to migrate?"
          end
          if !@tsearch_config[vector_name.intern]
            raise "Missing vector #{vector_name} in hash #{@tsearch_config.to_yaml}"
          else
            locale = @tsearch_config[vector_name.intern][:locale]
            fields = @tsearch_config[vector_name.intern][:fields]
            tables = @tsearch_config[vector_name.intern][:tables]
            if fields.is_a?(Array)
              sql = "update #{table_name} set #{vector_name} = to_tsvector(#{coalesce_array(fields)})"
            elsif fields.is_a?(String)
              sql = "update #{table_name} set #{vector_name} = to_tsvector(#{fields})"
            elsif fields.is_a?(Hash)
              if fields.size > 4
                raise "acts_as_tsearch currently only supports up to 4 weighted sets."
              else
                setweights = []
                ["a","b","c","d"].each do |f|
                  if fields[f]
                    setweights << "setweight( to_tsvector(#{coalesce_array(fields[f][:columns])}),'#{f.upcase}')"
                  end
                end
                sql = "update #{table_name} set #{vector_name} = #{setweights.join(" || ")}"
              end
            else
              raise ":fields was not an Array, Hash or a String."
            end
            from_arr = []
            where_arr = []
            if !tables.nil? and tables.is_a?(Hash)
              tables.keys.each do |k|
                from_arr << tables[k][:from]
                where_arr << tables[k][:where]
              end
              if from_arr.size > 0
                sql << " from " + from_arr.join(", ")
              end
            end
            if !row_id.nil?
              where_arr << "#{table_name}.id = #{row_id}"
            end
            if where_arr.size > 0
              sql << " where " + where_arr.join(" and ")
            end
            
            connection.execute(sql)
            #puts sql
          end #tsearch config test
        end
        
        def acts_as_tsearch_config
          @tsearch_config
        end
        
        def coalesce_array(arr)
          res = []
          arr.each do |f|
            res << "coalesce(#{f},'')"
          end
          return res.join(" || ' ' || ")        
        end

        def is_postgresql_83?
          self.postgresql_version >= 80300
        end
      end
      
      # Adds instance methods.
      module InstanceMethods
        
        def update_vector_row
          # self.class.tsearch_config.keys.each do |k|
          #    if self.class.tsearch_config[k][:auto_update_index] == true
          #      self.class.update_vector(self.id,k.to_s)
          
          #fixes STI problems - contributed by Craig Barber http://code.google.com/p/acts-as-tsearch/issues/detail?id=1&can=2&q=
          klass = self.class
          klass = klass.superclass while klass.tsearch_config.nil?
          klass.tsearch_config.keys.each do |k|
            if klass.tsearch_config[k][:auto_update_index] == true
              klass.update_vector(self.id,k.to_s)            
            end
          end
        end
        
      end

    end
  end
end

# reopen ActiveRecord and include all the above to make
# them available to all our models if they want it

ActiveRecord::Base.class_eval do
  include TsearchMixin::Acts::Tsearch
end
