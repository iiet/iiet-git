require 'spec_helper'

describe Projects::MergeRequestsController do
  let(:project) { create(:project) }
  let(:user)    { create(:user) }
  let(:merge_request) { create(:merge_request_with_diffs, target_project: project, source_project: project) }

  before do
    sign_in(user)
    project.team << [user, :master]
  end

  describe 'GET new' do
    context 'merge request that removes a submodule' do
      render_views

      let(:fork_project) { create(:forked_project_with_submodules) }

      before do
        fork_project.team << [user, :master]
      end

      it 'renders it' do
        get :new,
            namespace_id: fork_project.namespace.to_param,
            project_id: fork_project.to_param,
            merge_request: {
              source_branch: 'remove-submodule',
              target_branch: 'master'
            }

        expect(response).to be_success
      end
    end
  end

  describe "GET show" do
    shared_examples "export merge as" do |format|
      it "should generally work" do
        get(:show,
            namespace_id: project.namespace.to_param,
            project_id: project.to_param,
            id: merge_request.iid,
            format: format)

        expect(response).to be_success
      end

      it "should generate it" do
        expect_any_instance_of(MergeRequest).to receive(:"to_#{format}")

        get(:show,
            namespace_id: project.namespace.to_param,
            project_id: project.to_param,
            id: merge_request.iid,
            format: format)
      end

      it "should render it" do
        get(:show,
            namespace_id: project.namespace.to_param,
            project_id: project.to_param,
            id: merge_request.iid,
            format: format)

        expect(response.body).to eq(merge_request.send(:"to_#{format}").to_s)
      end

      it "should not escape Html" do
        allow_any_instance_of(MergeRequest).to receive(:"to_#{format}").
          and_return('HTML entities &<>" ')

        get(:show,
            namespace_id: project.namespace.to_param,
            project_id: project.to_param,
            id: merge_request.iid,
            format: format)

        expect(response.body).not_to include('&amp;')
        expect(response.body).not_to include('&gt;')
        expect(response.body).not_to include('&lt;')
        expect(response.body).not_to include('&quot;')
      end
    end

    describe "as diff" do
      it "triggers workhorse to serve the request" do
        get(:show,
            namespace_id: project.namespace.to_param,
            project_id: project.to_param,
            id: merge_request.iid,
            format: :diff)

        expect(response.headers[Gitlab::Workhorse::SEND_DATA_HEADER]).to start_with("git-diff:")
      end
    end

    describe "as patch" do
      it 'triggers workhorse to serve the request' do
        get(:show,
            namespace_id: project.namespace.to_param,
            project_id: project.to_param,
            id: merge_request.iid,
            format: :patch)

        expect(response.headers[Gitlab::Workhorse::SEND_DATA_HEADER]).to start_with("git-format-patch:")
      end
    end
  end

  describe 'GET index' do
    def get_merge_requests
      get :index,
          namespace_id: project.namespace.to_param,
          project_id: project.to_param,
          state: 'opened'
    end

    context 'when filtering by opened state' do
      context 'with opened merge requests' do
        it 'should list those merge requests' do
          get_merge_requests

          expect(assigns(:merge_requests)).to include(merge_request)
        end
      end

      context 'with reopened merge requests' do
        before do
          merge_request.close!
          merge_request.reopen!
        end

        it 'should list those merge requests' do
          get_merge_requests

          expect(assigns(:merge_requests)).to include(merge_request)
        end
      end
    end
  end

  describe 'PUT update' do
    context 'there is no source project' do
      let(:project)       { create(:project) }
      let(:fork_project)  { create(:forked_project_with_submodules) }
      let(:merge_request) { create(:merge_request, source_project: fork_project, source_branch: 'add-submodule-version-bump', target_branch: 'master', target_project: project) }

      before do
        fork_project.build_forked_project_link(forked_to_project_id: fork_project.id, forked_from_project_id: project.id)
        fork_project.save
        merge_request.reload
        fork_project.destroy
      end

      it 'closes MR without errors' do
        post :update,
            namespace_id: project.namespace.path,
            project_id: project.path,
            id: merge_request.iid,
            merge_request: {
              state_event: 'close'
            }

        expect(response).to redirect_to([merge_request.target_project.namespace.becomes(Namespace), merge_request.target_project, merge_request])
        expect(merge_request.reload.closed?).to be_truthy
      end
    end
  end

  describe 'POST merge' do
    let(:base_params) do
      {
        namespace_id: project.namespace.path,
        project_id: project.path,
        id: merge_request.iid,
        format: 'raw'
      }
    end

    context 'when the user does not have access' do
      before do
        project.team.truncate
        project.team << [user, :reporter]
        post :merge, base_params
      end

      it 'returns not found' do
        expect(response).to be_not_found
      end
    end

    context 'when the merge request is not mergeable' do
      before do
        merge_request.update_attributes(title: "WIP: #{merge_request.title}")

        post :merge, base_params
      end

      it 'returns :failed' do
        expect(assigns(:status)).to eq(:failed)
      end
    end

    context 'when the sha parameter does not match the source SHA' do
      before { post :merge, base_params.merge(sha: 'foo') }

      it 'returns :sha_mismatch' do
        expect(assigns(:status)).to eq(:sha_mismatch)
      end
    end

    context 'when the sha parameter matches the source SHA' do
      def merge_with_sha
        post :merge, base_params.merge(sha: merge_request.diff_head_sha)
      end

      it 'returns :success' do
        merge_with_sha

        expect(assigns(:status)).to eq(:success)
      end

      it 'starts the merge immediately' do
        expect(MergeWorker).to receive(:perform_async).with(merge_request.id, anything, anything)

        merge_with_sha
      end

      context 'when merge_when_build_succeeds is passed' do
        def merge_when_build_succeeds
          post :merge, base_params.merge(sha: merge_request.diff_head_sha, merge_when_build_succeeds: '1')
        end

        before do
          create(:ci_empty_pipeline, project: project, sha: merge_request.diff_head_sha, ref: merge_request.source_branch)
        end

        it 'returns :merge_when_build_succeeds' do
          merge_when_build_succeeds

          expect(assigns(:status)).to eq(:merge_when_build_succeeds)
        end

        it 'sets the MR to merge when the build succeeds' do
          service = double(:merge_when_build_succeeds_service)

          expect(MergeRequests::MergeWhenBuildSucceedsService).to receive(:new).with(project, anything, anything).and_return(service)
          expect(service).to receive(:execute).with(merge_request)

          merge_when_build_succeeds
        end

        context 'when project.only_allow_merge_if_build_succeeds? is true' do
          before do
            project.update_column(:only_allow_merge_if_build_succeeds, true)
          end

          it 'returns :merge_when_build_succeeds' do
            merge_when_build_succeeds

            expect(assigns(:status)).to eq(:merge_when_build_succeeds)
          end
        end
      end
    end
  end

  describe "DELETE destroy" do
    it "denies access to users unless they're admin or project owner" do
      delete :destroy, namespace_id: project.namespace.path, project_id: project.path, id: merge_request.iid

      expect(response).to have_http_status(404)
    end

    context "when the user is owner" do
      let(:owner)     { create(:user) }
      let(:namespace) { create(:namespace, owner: owner) }
      let(:project)   { create(:project, namespace: namespace) }

      before { sign_in owner }

      it "deletes the merge request" do
        delete :destroy, namespace_id: project.namespace.path, project_id: project.path, id: merge_request.iid

        expect(response).to have_http_status(302)
        expect(controller).to set_flash[:notice].to(/The merge request was successfully deleted\./).now
      end
    end
  end

  describe 'GET diffs' do
    def go(extra_params = {})
      params = {
        namespace_id: project.namespace.to_param,
        project_id: project.to_param,
        id: merge_request.iid
      }

      get :diffs, params.merge(extra_params)
    end

    context 'with default params' do
      context 'as html' do
        before { go(format: 'html') }

        it 'renders the diff template' do
          expect(response).to render_template('diffs')
        end
      end

      context 'as json' do
        before { go(format: 'json') }

        it 'renders the diffs template to a string' do
          expect(response).to render_template('projects/merge_requests/show/_diffs')
          expect(JSON.parse(response.body)).to have_key('html')
        end
      end

      context 'with forked projects with submodules' do
        render_views

        let(:project) { create(:project) }
        let(:fork_project) { create(:forked_project_with_submodules) }
        let(:merge_request) { create(:merge_request_with_diffs, source_project: fork_project, source_branch: 'add-submodule-version-bump', target_branch: 'master', target_project: project) }

        before do
          fork_project.build_forked_project_link(forked_to_project_id: fork_project.id, forked_from_project_id: project.id)
          fork_project.save
          merge_request.reload
          go(format: 'json')
        end

        it 'renders' do
          expect(response).to be_success
          expect(response.body).to have_content('Subproject commit')
        end
      end
    end

    context 'with ignore_whitespace_change' do
      context 'as html' do
        before { go(format: 'html', w: 1) }

        it 'renders the diff template' do
          expect(response).to render_template('diffs')
        end
      end

      context 'as json' do
        before { go(format: 'json', w: 1) }

        it 'renders the diffs template to a string' do
          expect(response).to render_template('projects/merge_requests/show/_diffs')
          expect(JSON.parse(response.body)).to have_key('html')
        end
      end
    end

    context 'with view' do
      before { go(view: 'parallel') }

      it 'saves the preferred diff view in a cookie' do
        expect(response.cookies['diff_view']).to eq('parallel')
      end
    end
  end

  describe 'GET diff_for_path' do
    def diff_for_path(extra_params = {})
      params = {
        namespace_id: project.namespace.to_param,
        project_id: project.to_param
      }

      get :diff_for_path, params.merge(extra_params)
    end

    context 'when an ID param is passed' do
      let(:existing_path) { 'files/ruby/popen.rb' }

      context 'when the merge request exists' do
        context 'when the user can view the merge request' do
          context 'when the path exists in the diff' do
            it 'enables diff notes' do
              diff_for_path(id: merge_request.iid, old_path: existing_path, new_path: existing_path)

              expect(assigns(:diff_notes_disabled)).to be_falsey
              expect(assigns(:comments_target)).to eq(noteable_type: 'MergeRequest',
                                                      noteable_id: merge_request.id)
            end

            it 'only renders the diffs for the path given' do
              expect(controller).to receive(:render_diff_for_path).and_wrap_original do |meth, diffs, diff_refs, project|
                expect(diffs.map(&:new_path)).to contain_exactly(existing_path)
                meth.call(diffs, diff_refs, project)
              end

              diff_for_path(id: merge_request.iid, old_path: existing_path, new_path: existing_path)
            end
          end

          context 'when the path does not exist in the diff' do
            before { diff_for_path(id: merge_request.iid, old_path: 'files/ruby/nopen.rb', new_path: 'files/ruby/nopen.rb') }

            it 'returns a 404' do
              expect(response).to have_http_status(404)
            end
          end
        end

        context 'when the user cannot view the merge request' do
          before do
            project.team.truncate
            diff_for_path(id: merge_request.iid, old_path: existing_path, new_path: existing_path)
          end

          it 'returns a 404' do
            expect(response).to have_http_status(404)
          end
        end
      end

      context 'when the merge request does not exist' do
        before { diff_for_path(id: merge_request.iid.succ, old_path: existing_path, new_path: existing_path) }

        it 'returns a 404' do
          expect(response).to have_http_status(404)
        end
      end

      context 'when the merge request belongs to a different project' do
        let(:other_project) { create(:empty_project) }

        before do
          other_project.team << [user, :master]
          diff_for_path(id: merge_request.iid, old_path: existing_path, new_path: existing_path, project_id: other_project.to_param)
        end

        it 'returns a 404' do
          expect(response).to have_http_status(404)
        end
      end
    end

    context 'when source and target params are passed' do
      let(:existing_path) { 'files/ruby/feature.rb' }

      context 'when both branches are in the same project' do
        it 'disables diff notes' do
          diff_for_path(old_path: existing_path, new_path: existing_path, merge_request: { source_branch: 'feature', target_branch: 'master' })

          expect(assigns(:diff_notes_disabled)).to be_truthy
        end

        it 'only renders the diffs for the path given' do
          expect(controller).to receive(:render_diff_for_path).and_wrap_original do |meth, diffs, diff_refs, project|
            expect(diffs.map(&:new_path)).to contain_exactly(existing_path)
            meth.call(diffs, diff_refs, project)
          end

          diff_for_path(old_path: existing_path, new_path: existing_path, merge_request: { source_branch: 'feature', target_branch: 'master' })
        end
      end

      context 'when the source branch is in a different project to the target' do
        let(:other_project) { create(:project) }

        before { other_project.team << [user, :master] }

        context 'when the path exists in the diff' do
          it 'disables diff notes' do
            diff_for_path(old_path: existing_path, new_path: existing_path, merge_request: { source_project: other_project, source_branch: 'feature', target_branch: 'master' })

            expect(assigns(:diff_notes_disabled)).to be_truthy
          end

          it 'only renders the diffs for the path given' do
            expect(controller).to receive(:render_diff_for_path).and_wrap_original do |meth, diffs, diff_refs, project|
              expect(diffs.map(&:new_path)).to contain_exactly(existing_path)
              meth.call(diffs, diff_refs, project)
            end

            diff_for_path(old_path: existing_path, new_path: existing_path, merge_request: { source_project: other_project, source_branch: 'feature', target_branch: 'master' })
          end
        end

        context 'when the path does not exist in the diff' do
          before { diff_for_path(old_path: 'files/ruby/nopen.rb', new_path: 'files/ruby/nopen.rb', merge_request: { source_project: other_project, source_branch: 'feature', target_branch: 'master' }) }

          it 'returns a 404' do
            expect(response).to have_http_status(404)
          end
        end
      end
    end
  end

  describe 'GET commits' do
    def go(format: 'html')
      get :commits,
          namespace_id: project.namespace.to_param,
          project_id: project.to_param,
          id: merge_request.iid,
          format: format
    end

    context 'as html' do
      it 'renders the show template' do
        go

        expect(response).to render_template('show')
      end
    end

    context 'as json' do
      it 'renders the commits template to a string' do
        go format: 'json'

        expect(response).to render_template('projects/merge_requests/show/_commits')
        expect(JSON.parse(response.body)).to have_key('html')
      end
    end
  end
end
