ARG RUBY_VERSION=3.3
FROM docker.io/library/ruby:${RUBY_VERSION}-slim

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

WORKDIR /shuron-rails

COPY Gemfile Gemfile.lock rails.gemspec RAILS_VERSION ./
COPY tools/ ./tools/
COPY railties/railties.gemspec ./railties/
COPY actionpack/actionpack.gemspec ./actionpack/
COPY actionview/actionview.gemspec ./actionview/
COPY activerecord/activerecord.gemspec ./activerecord/
COPY activesupport/activesupport.gemspec ./activesupport/
COPY activemodel/activemodel.gemspec ./activemodel/
COPY activejob/activejob.gemspec ./activejob/
COPY actionmailer/actionmailer.gemspec ./actionmailer/
COPY actioncable/actioncable.gemspec ./actioncable/
COPY activestorage/activestorage.gemspec ./activestorage/
COPY actionmailbox/actionmailbox.gemspec ./actionmailbox/
COPY actiontext/actiontext.gemspec ./actiontext/

RUN bundle install

COPY . .

CMD ["bash"]
