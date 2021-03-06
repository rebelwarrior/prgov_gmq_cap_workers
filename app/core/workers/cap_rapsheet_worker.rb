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
        # This error is not be a candidate for a retry thanks to BaseWorker.
        if !payload.has_key? "id"
          logger.error "#{self} is missing a transaction id, and cannot continue. "+
               "This should never happen. Check the GMQ API, responsible for "+
               "providing a proper id for this job."
          puts "#{self} is missing a transaction id, and cannot continue. "+
               "This should never happen. Check the GMQ API, responsible for "+
               "providing a proper id for this job. This job will not retry."
          raise MissingTransactionId
        end


        # Let's fetch the transaction from the Data Store.
        # The following line returns GMQ::Workers::TransactionNotFound
        # if the given Transaction id is not found in the system.
        # BaseWorker will not retry a job for a transaction that is not found.
        begin
          transaction = Transaction.find(payload["id"])
        # Detect any Transaction not found errors and log them properly
        rescue GMQ::Workers::TransactionNotFound => e
          logger.error "#{self} could not find transaction id "+
                       "#{payload["id"]}. This job will not be retried."
          puts "#{self} could not find transaction id #{payload["id"]}. This "+
               " job will not be retried."
          # re-raise so that it's caught by resque and the job isn't retried.
          raise e
        # When worker termination is requested via the SIGTERM signal,
        # Resque throws a Resque::TermException exception. Handling
        # this exception allows the worker to cease work on the currently
        # running job and gracefully save state by re-enqueueing the job so
        # it can be handled by another worker.
        # Every begin/rescue needs this rescue added
        rescue Resque::TermException
          Resque.enqueue(self, args)
        # log any other exceptions, but let resque retry according to our
        # BaseWorker specifications.
        rescue Exception => e
          logger.error "#{self} encountered a #{e.class.to_s} error while "+
               "fetching transaction #{payload["id"]}."
          puts "#{self} encountered a #{e.class.to_s} error while "+
               "fetching transaction #{payload["id"]}."
          # re-raise so that it's caught by resque
          raise e
        end




        # This flag determines if email notifications should be
        # supressed regarding generic notifications not related to
        # sending the actual certificate.
        #
        # This is used specifically when it is necessary to
        # invoke a request a second time manually, where a user has
        # already been notified in the past, and thus is uncessary to
        # mail them twice regarding this second attempt. While this
        # object is generally "indempotent", such that when it simply errors
        # out and is retried, the user is not notified on multiple occassions,
        # When running a process that has already completed succesfully
        # would in fact result in notifications upon success, we aim to
        # avoid this by incorporating this mute option.
        mute = false
        # Check if this worker should be invoked in mute mode,
        # where email notifcations are supressed. This is used in cases
        # where
        if (payload.has_key? "mute")
          if(payload["mute"].to_s == "true")
            logger.info "#{self} is activated in mute mode for "+
                        "#{transaction.id}, notifications will be supressed."
            mute = true
          end
        end

        # update the transaction status and save it
        transaction.status = "processing"
        transaction.state = :validating_rapsheet_with_sijc
        transaction.save

        # Grab the environment credentials for RCI
        user = ENV["SIJC_RCI_USER"]
        pass = ENV["SIJC_RCI_PASSWORD"]
        # generate url & query
        url = "#{ENV["SIJC_PROTOCOL"]}://#{ENV["SIJC_IP"]}#{ENV["SIJC_PORT"]}/v1/api/rap/request"

        query = ""
        query << "?tx_id=#{transaction.id}"
        query << "&first_name=#{transaction.first_name}"
        query << "&middle_name=#{transaction.middle_name}" if !transaction.middle_name.nil?
        query << "&last_name=#{transaction.last_name}"
        query << "&mother_last_name=#{transaction.mother_last_name}" if !transaction.mother_last_name.nil?
        query << "&ssn=#{transaction.ssn}" if transaction.ssn.to_s.length > 0
        query << "&passport=#{transaction.passport}" if transaction.passport.to_s.length > 0
        query << "&license=#{transaction.license_number}"
	query << "&requester_ip=#{transaction.IP}"
	query << "&requester_email=#{transaction.email}"
	query << "&residency_country=#{transaction.residency}"
	query << "&language=#{transaction.language}"
	query << "&reason=#{transaction.reason}"
	query << "&created_at=#{transaction.created_at}"
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
        logger.info "#{self} is transforming birthdate: #{transaction.birth_date} to epoch time #{epoch_time}."
        query << "&birth_date=#{epoch_time}"

        callback_url = "#{ENV["CAP_API_PUBLIC_PROTOCOL"]}://#{ENV["CAP_API_PUBLIC_IP"]}#{ENV["CAP_API_PUBLIC_PORT"]}/v1/cap/transaction/certificate_ready"
        query << "&callback_url=#{callback_url}"

        payload = ""
        # method = "put"
        # type = "json"
        method = "get"
        type   = "text/html; charset=utf-8"

        begin
          a = Rest.new(url, user, pass, type, payload, method, query)
          logger.info "#{self} is processing #{transaction.id}, "+
                      "requesting: URL: #{a.site}, METHOD: #{a.method}, "+
                      "TYPE: #{a.type}"
          response = a.request
          logger.info "HTTP Code: #{response.code}\n"+
                      "Headers: #{response.headers}\n"+
                      "Result: #{response.to_str}\n"
          puts        "HTTP Code: #{response.code}\n"+
                      "Headers: #{response.headers}\n"+
                      "Result: #{response.to_str}\n"
          case response.code
            when 200

              # Try to update the transaction info and stats,
              # ignore it if it fails. We have to ignore because
              # a retry at this step would result in multiple
              # calls and callbacks to RCI's API because of this
              # step, so we try and otherwise ignore any failures.
              # we don't want users or rci getting spammed.
              begin
                transaction.identity_validated = true
                transaction.location = "SIJC RCI"
                transaction.status = "waiting"
                transaction.state = :waiting_for_sijc_to_generate_cert
                transaction.save
              rescue Resque::TermException
                Resque.enqueue(self, args)
                # done - return reponse and wait for our sijc callback
              rescue Exception => e
                # continue
                puts "Error: #{e} ocurred"
              end

                  # Send messages relating to Fuzzy Result
                  if transaction.language == "english"
                    subject = "Your information has been verified successfully"
                    message = "We would like to inform you that the information "+
                              "provided to us regarding the request "+
                              "#{transaction.id}, has been verified "+
                              "successfully.\n\nPR.gov is now awaiting for the "+
                              "Police Department's systems to expedite a "+
                              "certificate, which we will send to you as "+
                              "as soon as it is received.\n\n"
                    html =    "We would like to inform you that the information "+
                              "provided to us regarding the request "+
                              "#{transaction.id}, has been verified "+
                              "successfully.\n\nPR.gov is now awaiting for the "+
                              "Police Department's systems to expedite a "+
                              "certificate, which we will send to you as "+
                              "as soon as it is received.\n\n"
                  else
                    # spanish
                    subject = "Su información se ha revisado exitosamente"
                    message = "Le informamos que la información relacionada "+
                              "a la solicitud con el número "+
                              "#{transaction.id}, ha sido verificada exitosamente.\n\n"+
                              "PR.gov estará en espera que los sistemas de "+
                              "la Policia de Puerto Rico expidan el certificado y "+
                              "nos lo entreguen. Una vez ese proceso culmine, "+
                              "le enviaremos a este correo "+
                              "el documento solicitado.\n\n"
                    html =    "Le informamos que la información relacionada "+
                              "a la solicitud con el número "+
                              "#{transaction.id}, ha sido verificada exitosamente.\n\n"+
                              "PR.gov estará en espera que los sistemas de "+
                              "la Policia de Puerto Rico expidan el certificado y "+
                              "nos lo entreguen. Una vez ese proceso culmine, "+
                              "le enviaremos a este correo "+
                              "el documento solicitado.\n\n"
                  end
                  html = html.gsub("\n", "<br/>")
                  if(!mute)
                    logger.info "#{self} is enqueing an EmailWorker for #{transaction.id}"
                    Resque.enqueue(GMQ::Workers::EmailWorker, {
                        "id"   => transaction.id,
                        "subject" => subject,
                        "text" => message,
                        "html" => html,
                    })
                  else
                    logger.info "#{self} is supressing EmailWorker for #{transaction.id}"
                  end

              # return the response
              response
            when 400
              json = JSON.parse(response)
              logger.error "RCI ERROR PAYLOAD: #{json["status"]} - "+
                                              "#{json["code"]} - "+
                                              "#{json["message"]}"


              # If this errored out because it requires an Analyst
              if (json["code"].to_s == "3005")
                  # Send messages relating to Fuzzy Result
                  if transaction.language == "english"
                    subject = "Your certificate request has been sent to an analyst for review"
                    message = "We would like to inform you that the information "+
                              "provided to us regarding the request "+
                              "#{transaction.id}, has been identified as requiring "+
                              "further analysis by the Police Department and was "+
                              "sent to an analyst for manual and careful revision. "+
                              "No further actions are required on your part. "+
                              "As soon as the Police Department analysts complete "+
                              "their task, which could take several days or weeks, you will "+
                              "receive another email from us.\n\n"+
                              "RCI Error: #{json["message"]}"
                    html =    "We would like to inform you that the information "+
                              "provided to us regarding the request "+
                              "#{transaction.id}, has been identified as requiring "+
                              "further analysis by the Police Department and was "+
                              "sent to an analyst for manual and careful revision. "+
                              "No further actions are required on your part. "+
                              "As soon as the Police Department analysts complete "+
                              "their task, which could take several days, you will "+
                              "receive another email from us.\n\n"+
                              "<i>RCI Error: #{json["message"]}</i>"
                  else
                    # spanish
                    subject = "Su solicitud de certificado ha sido enviado a un analista de la Policia para revisión"
                    message = "Le informamos que los datos "+
                              "tal cual nos han sido suministrados para la solicitud "+
                              "con el número '#{transaction.id}', se identificaron "+
                              "como que requieren una revisión manual por parte de "+
                              "los analistas de la Policia de Puerto Rico.\n\n"+
                              "Esto no necesita ninguna acción de su parte. "+
                              "Tan pronto los analistas de la Policia completen "+
                              "su labor de revisión, lo cual puede tomar varios dias o semanas, "+
                              "nos notificarán y usted recibirá un correo de "+
                              "nuestra parte con el resultado del mismo.\n\n"+
                              "RCI Error: #{json["message"]}"
                    html =    "Le informamos que la información "+
                              "tal como nos fue suministrada para la solicitud "+
                              "con el número '#{transaction.id}', fue identificada "+
                              "como que requiere una revisión manual por parte de "+
                              "los analistas de la Policia de Puerto Rico.\n\n"+
                              "Esto no necesita ninguna acción de su parte. "+
                              "Tan pronto los analistas de la Policia completen "+
                              "su labor de revisión, lo cual puede tardarse unos dias, "+
                              "nos notificarán y usted recibirá un correo de "+
                              "nuestra parte con el resultado del mismo.\n\n"+
                              "<i>RCI Error: #{json["message"]}</i>".gsub("\n", "<br/>")
                  end

                  # Try to update the transaction status,
                  # ignore it if it fails.
                  begin
                    # update the transaction
                    transaction.identity_validated = false
                    transaction.location = "RCI"
                    # TODO: update this status later so that if
                    # its a fuzzy result we mark as waiting
                    transaction.status = "pending"
                    transaction.state = :submitted_to_analyst_for_review
                    transaction.save
                  rescue Resque::TermException
                    Resque.enqueue(self, args)
                  rescue Exception => e
                    puts "Error: #{e} ocurred"
                    logger.error "#{self} encountered an #{e} error while updating transaction. Ignoring."
                  end

                  html = html.gsub("\n", "<br/>")
                  if(!mute)
                    logger.info "#{self} is enqueing an EmailWorker for #{transaction.id}"
                    Resque.enqueue(GMQ::Workers::EmailWorker, {
                        "id"   => transaction.id,
                        "subject" => subject,
                        "text" => message,
                        "html" => html,
                    })
                  else
                    logger.info "#{self} is supressing EmailWorker for #{transaction.id}"
                  end
              else
                # all other errors
                if transaction.language == "english"
                  subject = "We could not validate your information"
                  message = "We regret to inform you that the information "+
                            "provided to us for "+
                            "the request #{transaction.id}, did not match "+
                            "the information stored in our government systems. "+
                            "When requesting a Goodstanding Certificate "+
                            "it's important to make sure that the information "+
                            "you provide matches exactly the information "+
                            "as it appears in the ID of the "+
                            "identification method you've selected.\n\n"+
                            "RCI Error: #{json["message"]}"
                  html =    "We regret to inform you that the information "+
                            "provided to us for "+
                            "the request #{transaction.id}, did not match "+
                            "the information stored in our government systems. "+
                            "When requesting a Goodstanding Certificate "+
                            "it's important to make sure that the information "+
                            "you provide matches exactly the information "+
                            "as it appears in the ID of the "+
                            "identification method you've selected.\n\n"+
                            "<i>RCI Error: #{json["message"]}</i>"
                else
                  # spanish
                  subject = "Error en la validación de su solicitud"
                  message = "Le informamos que los datos "+
                            "tal cual nos han sido suministrados para la solicitud "+
                            "con el número '#{transaction.id}', no fueron "+
                            "identificados en los sistemas gubernamentales.\n\n"+
                            "Al solicitar el Certificado de Antecedentes "+
                            "Penales debe asegurarse solicitar con la "+
                            "información tal cual "+
                            "aparece en el ID del método de "+
                            "identificación seleccionado.\n\n"+
                            "RCI Error: #{json["message"]}"
                  html =    "Le informamos que los datos "+
                            "tal cual nos han sido suministrados para la solicitud "+
                            "con el número '#{transaction.id}', no fueron "+
                            "identificados en los sistemas gubernamentales.\n\n"+
                            "Al solicitar el Certificado de Antecedentes "+
                            "Penales debe asegurarse solicitar con la "+
                            "información tal cual "+
                            "aparece en el ID del método de "+
                            "identificación seleccionado.\n\n"+
                            "<i>RCI Error: #{json["message"]}</i>".gsub("\n", "<br/>")
                end

                # Try to update the transaction status,
                # ignore it if it fails.
                begin
                  # update the transaction
                  transaction.identity_validated = false
                  transaction.location = "Mail"
                  # TODO: update this status later so that if
                  # its a fuzzy result we mark as waiting
                  transaction.status = "completed"
                  transaction.state = :failed_validating_rapsheet_with_sijc
                  transaction.save
                  # update global statistics
                  transaction.remove_pending
                  transaction.add_completed
                rescue Resque::TermException
                  Resque.enqueue(self, args)
                rescue Exception => e
                  puts "Error: #{e} ocurred"
                  logger.error "#{self} encountered an #{e} error while updating transaction. Ignoring."
                end

                html = html.gsub("\n", "<br/>")
                if(!mute)
                  logger.info "#{self} is enqueing an EmailWorker for #{transaction.id}"
                  Resque.enqueue(GMQ::Workers::EmailWorker, {
                      "id"   => transaction.id,
                      "subject" => subject,
                      "text" => message,
                      "html" => html,
                  })
                else
                  logger.info "#{self} is supressing EmailWorker for #{transaction.id}"
                end
              end


              # ENQUE WORKER to notify USER of faliled communication
              # with SIJC's RCI.

              # Here we should go error by error to identify exactly
              # what SIJC mentioned and deal with it accordingly
              # and notify the user after x amount of failures.
              # We could catch each error eventually, for now
              # a generic catch for 400s.

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
              # The service couldn’t identify precisely the information submitted.
              # How this differs from a fuzzy search isn't clear.
              # 400
              # 3003
              #
              #
              # Error 3004, 3003 and 3002 were deprecated by LoS RCI docs.
              # New error 3005 encompasses all errors that requires an analyst
              # intervention at PRPD.
              #
              # One or more of the antecedents found don't have a final disposition.
              # Further analysis is required.","status":400,"code":3004}
              #
              #
              # DTOP service is down or having a problem.
              # 500
              # 4000
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
              # do proper notification of the problem:
              logger.error "#{self} received 500 error when processing "+
              "#{transaction.id} and connecting to URL: #{a.site}, METHOD: "+
              "#{a.method}, TYPE: #{a.type}."
              puts "#{self} received 500 error when processing "+
              "#{transaction.id} and connecting to URL: #{a.site}, METHOD: "+
              "#{a.method}, TYPE: #{a.type}."

              # add error statistics to this transaction
              # later we could check wether the error is
              # a specific code or not.
              begin
                transaction.rci_error_count = (transaction.rci_error_count.to_i) + 1
                transaction.rci_error_date  = Time.now
                transaction.last_error_type = "#{e}"
                transaction.last_error_date = Time.now
                transaction.status = "retrying"
                transaction.state = :error_validating_rapsheet_with_sijc
                transaction.save
              rescue Resque::TermException
                Resque.enqueue(self, args)
              rescue Exception => e
                puts "Error: #{e} ocurred"
              end

              response.return!(request, result, &block)
            # Any other http error codes are processed. Such as 301, 302
            # redirections, etc are properly processed and we allow Restclient
            # to decide what to do in those cases, such as follow, or throw
            # Exceptions
            else
              response.return!(request, result, &block)
          end
        rescue RestClient::Exception => e
          logger.error "Error #{e} while processing #{transaction.id}. "+
          "WORKER REQUEST: URL: #{a.site}, METHOD: #{a.method}, TYPE: #{a.type} "+
          "Error detail: MESSAGE: #{e.message} - DETAIL: #{e.inspect.to_s}."
          puts "Error #{e} while processing #{transaction.id}. "+
          "WORKER REQUEST: URL: #{a.site}, METHOD: #{a.method}, TYPE: #{a.type} "+
          "Error detail: #{e.inspect.to_s} MESSAGE: #{e.message}."
          # add error statistics to this transaction
          begin
            transaction.rci_error_count = (transaction.rci_error_count.to_i) + 1
            transaction.rci_error_date  = Time.now
            transaction.last_error_type = "#{e}"
            transaction.last_error_date = Time.now
            transaction.status = "retrying"
            transaction.state = :error_validating_rapsheet_with_sijc
            transaction.save
          rescue Resque::TermException
            Resque.enqueue(self, args)
          rescue Exception => e
            # continue
            puts "Error: #{e} ocurred"
          end
          raise GMQ::RCI::ApiError, "#{e.inspect.to_s} - WORKER REQUEST: "+
          "URL: #{a.site}, METHOD: #{a.method}, TYPE: #{a.type}"
        # Timed out - Happens when a network error doesn't permit
        # us to communicate with the remote API.
        rescue Errno::ETIMEDOUT => e
          logger.error "Could Not Connect - #{e} while processing #{transaction.id}. "+
          "WORKER REQUEST: URL: #{a.site}, METHOD: #{a.method}, TYPE: #{a.type} "+
          "Error detail: MESSAGE: #{e.message} - DETAIL: #{e.inspect.to_s}."
          puts "Error #{e} while processing #{transaction.id}. "+
          "WORKER REQUEST: URL: #{a.site}, METHOD: #{a.method}, TYPE: #{a.type} "+
          "Error detail: #{e.inspect.to_s} MESSAGE: #{e.message}."

          # add error statistics to this transaction but ignore
          # any errors when doing so
          begin
            transaction.rci_error_count = (transaction.rci_error_count.to_i) + 1
            transaction.rci_error_date  = Time.now
            transaction.last_error_type = "#{e}"
            transaction.last_error_date = Time.now
            transaction.status = "retrying"
            transaction.state = :failed_validating_rapsheet_with_sijc
            transaction.save
          # When worker termination is requested via the SIGTERM signal
          rescue Resque::TermException
            Resque.enqueue(self, args)
          rescue Exception => e
            # ignore errors and continue
            puts "Error: #{e} ocurred"
          end

          raise GMQ::RCI::ConnectionTimedout, "#{self} #{e.inspect.to_s} - WORKER REQUEST: "+
          "URL: #{a.site}, METHOD: #{a.method}, TYPE: #{a.type}"
        # Catch SIGTERM and Renenque
        rescue Resque::TermException
          Resque.enqueue(self, args)
        # Everything else
        rescue Exception => e
          # we will catch and rethrow the error.
          logger.error "#{e} while processing #{transaction.id}. "+
          "WORKER REQUEST: URL: #{a.site}, METHOD: #{a.method}, TYPE: #{a.type} "+
          "Error detail: MESSAGE: #{e.message} - DETAIL: #{e.inspect.to_s}."
          puts "Error #{e} while processing #{transaction.id}. "+
          "WORKER REQUEST: URL: #{a.site}, METHOD: #{a.method}, TYPE: #{a.type} "+
          "Error detail: MESSAGE: #{e.message} Detail: #{e.inspect.to_s}."
          # add error statistics to this transaction
          # errors here might include things that won't let us perform
          # this step, so we wrap this in a begin/rescue and ignore errors
          # from this attempt. If it works great, if not. Read the logs.
          begin
            transaction.rci_error_count = (transaction.rci_error_count.to_i) + 1
            transaction.rci_error_date  = Time.now
            transaction.last_error_type = "#{e}"
            transaction.last_error_date = Time.now
            transaction.status = "waiting"
            transaction.state = :failed_validating_rapsheet_with_sijc
            transaction.save
          rescue Resque::TermException
            Resque.enqueue(self, args)
          rescue Exception => e
            puts "Error: #{e} ocurred"
          end
          # now raise the error
          raise e
        end # end of begin/rescue

        # When worker termination is requested via the SIGTERM signal,
        # Resque throws a Resque::TermException exception. Handling
        # this exception allows the worker to cease work on the currently
        # running job and gracefully save state by re-enqueueing the job so
        # it can be handled by another worker.
        # Every begin/rescue needs this rescue added
        rescue Resque::TermException
          Resque.enqueue(self, args)
      end # end of perform
    end # end of class
  end # end of worker module
end # end of GMQ module
