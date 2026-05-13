FROM ghcr.io/naoya0117/shuron-rails:latest

WORKDIR /rails

# Temporarily remove GEM_PATH so Ruby can find bundled gems (e.g. minitest) from the system path
RUN env -u GEM_PATH rails new . --skip-bundle --force

# Use the pre-installed forked Rails (already in base image at /usr/local/bundle)
RUN sed -i 's/^gem "rails", "~> .*"/gem "rails", "8.1.2"/' Gemfile

RUN bundle install

EXPOSE 3000
CMD ["bin/rails", "server", "-b", "0.0.0.0"]
