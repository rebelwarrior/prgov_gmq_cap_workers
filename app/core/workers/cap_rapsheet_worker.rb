# Require the base functionality (config, helpers, errors, etc)
require 'app/core/workers/base_worker'
# Transaction capabilities
require 'app/models/transaction'
# Restful capabilities
require 'app/helpers/rest'

module GMQ
  module Workers
    class RapsheetWorker < GMQ::Workers::BaseWorker

      def self.perform(*args)
        super # call base worker perform
        payload = args[0]

        # get the ID from the params. If it is missing, we error out.
        # TODO This error should not be a candidate for a retry
        raise MissingTransactionId if !payload.has_key? "id"

        # Let's fetch the transaction from the Data Store.
        # The following line returns GMQ::Workers::TransactionNotFound
        # if the given Transaction id is not found in the system.
        # BaseWorker will not retry a job for a transaction that is not found.
        transaction = Transaction.find(payload["id"])

        # Grab the environment credentials for RCI
        user = ENV["SIJC_RCI_USER"]
        pass = ENV["SIJC_RCI_PASSWORD"]
        # generate url & query
        # url = "https://66.50.173.6/v1/api/rap/request"
        # url = "http://localhost:9000/v1/cap/"
        url = "#{ENV["SIJC_PROTOCOL"]}://#{ENV["SIJC_IP"]}#{ENV["SIJC_PORT"]}/v1/api/rap/request"

        query = ""
        query << "?tx_id=#{transaction.id}"
        query << "&first_name=#{transaction.first_name}"
        query << "&middle_name=#{transaction.middle_name}" if !transaction.middle_name.nil?
        query << "&last_name=#{transaction.last_name}"
        query << "&mother_last_name=#{transaction.mother_last_name}" if !transaction.mother_last_name.nil?
        query << "&ssn=#{transaction.ssn}"
        query << "&license=#{transaction.license_number}"
        # Due to what we could only describe as an unfortunate accident or
        # evil incarnate joke on SIJC's part, RCI API requires the date
        # in miliseconds since epoch, so we parse
        # the CAP API date which is in the format of dd/mm/yyyy and
        # convert to miliseconds since epoch. However
        # we can't simply use DateTime.parse, because it assumes UTC.
        # Since our PR timezone is in -0400
        # lets add four hours to the UTC clock, so that we end up at 12am
        # for the specific date in our timezone when converting to time since
        # epoch. Note, if you don't add the 4 hours, you end up in the day
        # before. Thus, writing this next line was as 'fun' as it sounds.
        epoch_time = DateTime.strptime("#{transaction.birth_date} 4",
                                       "%d/%m/%Y %H").strftime("%Q")
        logger.info "Transforming birthdate: #{transaction.birth_date} to epoch time #{epoch_time}."
        query << "&birth_date=#{epoch_time}"

        callback_url = "#{ENV["CAP_API_PUBLIC_PROTOCOL"]}://#{ENV["CAP_API_PUBLIC_IP"]}#{ENV["CAP_API_PUBLIC_PORT"]}/v1/cap/transaction/certificate_ready"
        query << "&callback_url=#{callback_url}"

        payload = ""
        # method = "put"
        # type = "json"
        method = "get"
        type   = "text/html; charset=utf-8"

        begin
        # raise AppError, "#{url}, #{user}, #{pass}, #{type}, #{payload}, #{method}"
          a = Rest.new(url, user, pass, type, payload, method, query)
          logger.info "#{self} is processing #{transaction.id}, "+
                      "requesting: URL: #{a.site}, METHOD: #{a.method}, "+
                      "TYPE: #{a.type}"
          response = a.request
          logger.info "HTTP Code:\n#{response.code}\n\n"
          logger.info "Headers:\n#{response.headers}\n\n"
          logger.info "Result:\n#{response.gsub(",", ",\n").to_str}\n"
          case response.code
            when 200
              response
            when 400
              json = JSON.parse(response)
              logger.error "RCI ERROR PAYLOAD: #{json["status"]} - "+
                                              "#{json["code"]} - "+
                                              "#{json["message"]}"

              # ENQUE WORKER to notify USER of faliled communication
              # with SIJC's RCI.

              # Here we should go error by error to identify exactly
              # what SIJC mentioned and deal with it accordingly
              # and notify the user. We need to catch each error.

              # Eror Responses
              # Description
              # Http Status Code
              # Application Code
              # Message
              # The social security number is a required parameter for the request.
              # 400
              # 1001
              # Parameter: ssn is required.
              #
              # The license number is a required parameter for the request.
              # 400
              # 1002
              #
              # Parameter: license_number is required.
              # The first name is a required parameter for the request.
              # 400
              # 1003
              #
              # Parameter: first_name is required.
              # The last name is a required parameter for the request.
              # 400
              # 1004
              #
              # Parameter: last_name is required.
              # The birth date is a required parameter for the request.
              # 400
              # 1005
              #
              # Parameter: birth_date is required.
              # The value provided on the birth date does not correspond to a valid date.
              # 400
              # 1006
              #
              # The birth date provided does not represent a valid birth date.
              # The social security number provided does not match with the social security number on the record identified on the external service.
              # 400
              # 2001
              #
              # Invalid ssn provided.
              # The license number provided does not match name on the record identified on the external service.
              # 400
              # 2002
              #
              # Invalid license number provided.
              # The name provided does not match name on the record identified on the external service.
              # 400
              # 2003
              #
              # Invalid name provided.
              # The birth date provided does not match birth date on the record identified on the external service.
              # 400
              # 2004
              #
              # Invalid birth date provided.
              # The external service did not return any results matching the search criteria.
              # 400
              # 3001
              #
              # Could not identify individual on external service.
              # The external service returned multiple results matching the search criteria.
              # 400
              # 3002
              #
              # Multiple results found on external service. DTOP.
              # The service couldn’t identify precisely the information submitted. This is what we call a fuzzy search.
              # 400
              # 3003
              #
              #
              # Fuzzy Search. Couldn't identify properly the profile on the criminal record registry.
              # The document store is having problems persisting requests or it’s simply down.
              # 500
              # 8000
              #
              # The service is having trouble communicating with MongoDB or something was wrong saving the
              # An unexpected error ocurred while processing the request.
              # 500
              # 9999
              # Unexpected Error.


            # 500 errors are internal server errors. They will be
            # retried. Here we allow RestClient to raise an Exception
            # which will be caught by the system and retried.
            when 500
              response.return!(request, result, &block)
            # Any other http error codes are processed. Such as 301, 302
            # redirections, etc are properly processed and we allow Restclient
            # to decide what to do in those cases, such as follow, or throw
            # Exceptions
            else
              response.return!(request, result, &block)
          end
        rescue RestClient::Exception => e
          logger.error "Error #{e} while processing #{transaction.id}: #{e.inspect.to_s}"+
          " MESSAGE: #{e.message}"

          raise GMQ::RCI::ApiError, "#{e.inspect.to_s} - WORKER REQUEST: "+
          "URL: #{a.site}, METHOD: #{a.method}, TYPE: #{a.type}"
        end
      end # end of perform
    end # end of class
  end # end of worker module
end # end of GMQ module
