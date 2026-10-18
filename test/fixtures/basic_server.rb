require "spinner"
class BasicApplication
  def call(env)
    [200, {}, ["OK"]]
  end
end
Spinner::Server.new(BasicApplication.new, port: 0).run
